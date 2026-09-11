defmodule Pinha.Ssh do
  @moduledoc """
  The SSH listener: Erlang's own `ssh` daemon, inside this release.

  There is no OpenSSH, no OS account per user, and no `authorized_keys` file.
  Every client connects as one SSH username, `git`, and identity comes from
  the key: `Pinha.Ssh.KeyCb` resolves an offered key to a user during
  authentication and records the binding here, and `Pinha.Ssh.Channel` reads
  it back when the session asks to run git.

  The binding is keyed by the connection process, which is the same process
  that authenticated it, and dropped when that process dies.
  """

  use GenServer

  alias Pinha.Accounts.SshKey
  alias Pinha.Config
  alias Pinha.Ssh.Channel
  alias Pinha.Ssh.KeyCb

  require Logger

  @sessions :pinha_ssh_sessions
  @host_key_file "ssh_host_ed25519_key"
  # Ed25519 in PKCS#8 PEM, which is what OTP's own host key reader takes.
  @host_key_type :PrivateKeyInfo

  def start_link(opts),
    do: GenServer.start_link(__MODULE__, :ok, Keyword.put_new(opts, :name, __MODULE__))

  @doc """
  The port the listener actually bound, or nil when SSH is switched off.

  It is the configured port everywhere but the suite, which asks the OS for
  one; clone URLs read it from here so they name the port a client can reach.
  """
  @spec port() :: non_neg_integer() | nil
  def port, do: :persistent_term.get({__MODULE__, :port}, nil)

  @doc """
  Records that `connection` authenticated as the user with this `uid`.

  Called from the connection process itself during authentication, so the
  channel that later runs git finds the user without a second lookup.
  """
  @spec bind(pid(), String.t()) :: :ok
  def bind(connection, uid) do
    :ets.insert(@sessions, {connection, uid})
    GenServer.cast(__MODULE__, {:watch, connection})
  end

  @doc "The `uid` bound to a connection, or nil when nothing authenticated it."
  @spec uid_for(pid()) :: String.t() | nil
  def uid_for(connection) do
    case :ets.lookup(@sessions, connection) do
      [{^connection, uid}] -> uid
      [] -> nil
    end
  rescue
    ArgumentError -> nil
  end

  @impl true
  def init(:ok) do
    :ets.new(@sessions, [:named_table, :public, :set, read_concurrency: true])

    if Config.ssh_enabled?() do
      {:ok, start_daemon()}
    else
      {:ok, %{daemon: nil, port: nil}}
    end
  end

  @impl true
  def handle_cast({:watch, connection}, state) do
    Process.monitor(connection)
    {:noreply, state}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    :ets.delete(@sessions, pid)
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, %{daemon: daemon}) when not is_nil(daemon) do
    :persistent_term.erase({__MODULE__, :port})
    :ssh.stop_daemon(daemon)
  end

  def terminate(_reason, _state), do: :ok

  defp start_daemon do
    dir = ensure_host_key!()

    options = [
      system_dir: to_charlist(dir),
      auth_methods: ~c"publickey",
      key_cb: {KeyCb, []},
      ssh_cli: {Channel, []},
      subsystems: [],
      # A session runs git and nothing else, so nothing here needs a terminal
      # or a tunnel out of the box it lands in.
      tcpip_tunnel_in: false,
      tcpip_tunnel_out: false,
      max_sessions: 64,
      id_string: :random
    ]

    options =
      case Config.ssh_listen_ip() do
        nil -> options
        ip -> Keyword.put(options, :ip, ip)
      end

    case :ssh.daemon(Config.ssh_port(), options) do
      {:ok, daemon} ->
        port = bound_port(daemon)
        :persistent_term.put({__MODULE__, :port}, port)
        Logger.info("ssh listening on port #{port}, host key #{host_key_fingerprint(dir)}")
        %{daemon: daemon, port: port}

      {:error, reason} ->
        Logger.error("ssh listener failed to start: #{inspect(reason)}")
        %{daemon: nil, port: nil}
    end
  end

  defp bound_port(daemon) do
    case :ssh.daemon_info(daemon) do
      {:ok, info} -> Keyword.get(info, :port)
      _ -> nil
    end
  end

  @doc """
  Generates the host key on first boot, and returns the directory holding it.

  The key persists across restarts and deploys: a regenerated one fails every
  client's `known_hosts` check. It sits under the repo root by default, which
  the repo listing skips and a backup of the root carries along.
  """
  @spec ensure_host_key!() :: String.t()
  def ensure_host_key! do
    dir = Config.ssh_host_key_dir()
    path = Path.join(dir, @host_key_file)

    unless File.exists?(path) do
      File.mkdir_p!(dir)
      File.chmod!(dir, 0o700)

      key = :public_key.generate_key({:namedCurve, :ed25519})
      pem = :public_key.pem_encode([:public_key.pem_entry_encode(@host_key_type, key)])

      File.write!(path, pem)
      File.chmod!(path, 0o600)
      File.write!(path <> ".pub", :ssh_file.encode([{public_part(key), []}], :auth_keys))
    end

    dir
  end

  defp host_key_fingerprint(dir) do
    with {:ok, pem} <- File.read(Path.join(dir, @host_key_file)),
         [entry] <- :public_key.pem_decode(pem),
         key <- :public_key.pem_entry_decode(entry),
         {:ok, fingerprint} <- SshKey.fingerprint(public_part(key)) do
      SshKey.format_fingerprint(fingerprint)
    else
      _ -> "unreadable"
    end
  end

  # An Ed25519 private key carries its public half in the fifth field, and the
  # curve is named by OID in the form ssh encodes.
  defp public_part(key), do: {{:ECPoint, elem(key, 4)}, {:namedCurve, {1, 3, 101, 112}}}
end
