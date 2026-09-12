defmodule Pinha.Ssh.Channel do
  @moduledoc """
  One SSH session, which may run git once and do nothing else.

  The session is already authenticated when it gets here: `Pinha.Ssh.KeyCb`
  bound a user to the connection, and this reads that binding back. What
  arrives is a single exec request, parsed without a shell into one of two
  verbs and one repository, after which git is spawned from an argv list with
  its stdin and stdout wired to the channel.

  A shell, a terminal, a subsystem, forwarding, a second exec, or an
  environment variable other than `GIT_PROTOCOL` is refused: a stolen key buys
  a git session and no more.
  """

  @behaviour :ssh_server_channel

  alias Pinha.Accounts
  alias Pinha.Config
  alias Pinha.Git
  alias Pinha.Git.PktLine
  alias Pinha.Maintenance
  alias Pinha.Repos
  alias Pinha.Ssh
  alias Pinha.Widelog

  require Logger
  require OpenTelemetry.Tracer, as: Tracer

  alias OpenTelemetry.Span

  # Protocol v2 is the one thing a client may put in the environment. Anything
  # else would let a session name object directories or config files of its
  # own and read outside the repository it asked for.
  @protocol_env "GIT_PROTOCOL"
  @protocol_value ~r/\A[a-zA-Z0-9=.:,\-]{1,100}\z/

  @command_scan_bytes 65_536
  @idle_timeout 300_000

  defmodule State do
    @moduledoc false
    defstruct [
      :id,
      :cm,
      :port,
      :repo,
      :subcommand,
      :user,
      :protocol,
      :started_at,
      :timer,
      :peer,
      :stderr_path,
      :span,
      scan: <<>>,
      refs: nil,
      finished: false,
      req_bytes: 0,
      resp_bytes: 0
    ]
  end

  @impl true
  def init(_opts), do: {:ok, %State{}}

  @impl true
  def handle_msg({:ssh_channel_up, id, cm}, state) do
    # The clock starts at the channel, not at the exec, so a session that
    # opens and then says nothing is dropped like any other idle one.
    {:ok, arm(%{state | id: id, cm: cm, peer: peer(cm)})}
  end

  def handle_msg({port, {:data, data}}, %State{port: port} = state) do
    case :ssh_connection.send(state.cm, state.id, data) do
      :ok -> {:ok, %{arm(state) | resp_bytes: state.resp_bytes + byte_size(data)}}
      {:error, _reason} -> stop(state)
    end
  end

  def handle_msg({port, {:exit_status, status}}, %State{port: port} = state) do
    finish(%{state | port: nil}, status)
  end

  def handle_msg(:idle, state) do
    Logger.warning("ssh session idle for #{@idle_timeout}ms, closing")
    finish(state, 1)
  end

  def handle_msg(_msg, state), do: {:ok, state}

  @impl true
  def handle_ssh_msg({:ssh_cm, cm, {:exec, id, want_reply, command}}, state) do
    :ssh_connection.reply_request(cm, want_reply, :success, id)
    start(state, to_string(command))
  end

  def handle_ssh_msg({:ssh_cm, _cm, {:data, _id, 0, data}}, %State{port: port} = state)
      when not is_nil(port) do
    command(state, data)
    :ssh_connection.adjust_window(state.cm, state.id, byte_size(data))

    {:ok, scan(%{arm(state) | req_bytes: state.req_bytes + byte_size(data)}, data)}
  end

  def handle_ssh_msg({:ssh_cm, _cm, {:data, _id, _type, _data}}, state), do: {:ok, state}

  def handle_ssh_msg({:ssh_cm, cm, {:env, id, want_reply, var, value}}, state) do
    {reply, state} = put_env(state, to_string(var), to_string(value))
    :ssh_connection.reply_request(cm, want_reply, reply, id)
    {:ok, state}
  end

  def handle_ssh_msg({:ssh_cm, cm, {:shell, id, want_reply}}, state) do
    :ssh_connection.reply_request(cm, want_reply, :success, id)
    deny(state, "this server runs git and nothing else; there is no shell here")
  end

  def handle_ssh_msg({:ssh_cm, cm, {:pty, id, want_reply, _options}}, state) do
    :ssh_connection.reply_request(cm, want_reply, :failure, id)
    {:ok, state}
  end

  def handle_ssh_msg({:ssh_cm, cm, {:subsystem, id, want_reply, _name}}, state) do
    :ssh_connection.reply_request(cm, want_reply, :failure, id)
    {:ok, state}
  end

  # A client that has nothing more to say closes its side. An Erlang port
  # cannot close one direction of a pipe, so the flush packet that ends a
  # protocol v2 session is sent in place of the EOF git is waiting for;
  # without it `upload-pack` sits reading stdin after the pack is delivered
  # and the client waits for a process that never exits.
  def handle_ssh_msg({:ssh_cm, _cm, {:eof, _id}}, state) do
    command(state, PktLine.flush())
    {:ok, state}
  end

  def handle_ssh_msg({:ssh_cm, _cm, {:closed, _id}}, state), do: stop(state)

  def handle_ssh_msg({:ssh_cm, _cm, _msg}, state), do: {:ok, state}

  # A client that goes away mid-clone never reaches `finish/2`: the channel is
  # closed under it. Reporting the session here as well is what keeps an
  # abandoned push in the log and its span out of the SDK's dropped pile.
  @impl true
  def terminate(_reason, state) do
    unless state.finished, do: report(state, 130)
    close_port(state)
    if state.stderr_path, do: File.rm(state.stderr_path)
    :ok
  end

  ## Running git

  defp start(state, command) do
    # The span opens before the command is understood, so a refused session is
    # a span too rather than a gap.
    span =
      Tracer.start_span("ssh exec", %{
        attributes: [{"transport", "ssh"}, {"peer", state.peer || ""}]
      })

    Tracer.set_current_span(span)

    state = %{state | started_at: System.monotonic_time(), span: span}

    with {:ok, subcommand, name} <- parse(command),
         {:ok, user} <- authenticated(state),
         {:ok, repo} <- repository(name),
         :ok <- authorize(subcommand, repo, user) do
      Span.update_name(span, "git #{subcommand}")

      Span.set_attributes(
        span,
        [{"user", user.id}] ++ Git.span_attributes(repo.dir, subcommand, [subcommand])
      )

      spawn_git(%{state | subcommand: subcommand, repo: repo, user: user})
    else
      {:error, message} -> deny(state, message)
    end
  end

  defp parse(command) do
    case Pinha.Ssh.Command.parse(command) do
      {:ok, subcommand, name} ->
        {:ok, subcommand, name}

      {:error, :unsupported} ->
        {:error, "only git-upload-pack and git-receive-pack may run here"}

      {:error, :invalid_name} ->
        {:error, "invalid repository name"}
    end
  end

  # The connection authenticated with a key, so the user is already known; a
  # user deleted between authentication and exec is simply gone.
  defp authenticated(state) do
    with uid when is_binary(uid) <- Ssh.uid_for(state.cm),
         {:ok, user} <- Accounts.fetch_user_by_uid(uid) do
      {:ok, user}
    else
      _ -> {:error, "this key is not registered to a user"}
    end
  end

  defp repository(name) do
    case Repos.fetch(name) do
      {:ok, repo} -> {:ok, repo}
      {:error, :not_found} -> {:error, "no such repository: #{name}"}
      {:error, :invalid_repo} -> {:error, "#{name} is not a valid bare repository"}
      {:error, :invalid_name} -> {:error, "invalid repository name"}
    end
  end

  # Reading is open to every authenticated user; writing is the owner and
  # admins, decided by the function the HTTP transport calls too.
  defp authorize("upload-pack", _repo, _user), do: :ok

  defp authorize("receive-pack", repo, user) do
    if Repos.writable_by?(repo, user) do
      :ok
    else
      {:error, "you do not have push access to #{repo.name}"}
    end
  end

  defp spawn_git(state) do
    case System.find_executable(Config.git_bin()) do
      nil ->
        Logger.error("git executable #{Config.git_bin()} not found")
        deny(state, "git is not available on this server")

      git ->
        # Run under /bin/sh only to redirect stderr to a file. The command is
        # fixed and the arguments arrive as positional parameters, so nothing
        # the client sent is parsed by the shell.
        stderr = Git.stderr_path()

        port =
          Port.open({:spawn_executable, "/bin/sh"}, [
            :binary,
            :exit_status,
            :hide,
            args: Git.shell_args(git, [state.subcommand, state.repo.dir]),
            cd: state.repo.dir,
            env: env(%{state | stderr_path: stderr})
          ])

        {:ok, arm(%{state | port: port, stderr_path: stderr})}
    end
  end

  defp env(state) do
    extra = if state.protocol, do: [{@protocol_env, state.protocol}], else: []
    extra = if state.stderr_path, do: [{Git.stderr_var(), state.stderr_path} | extra], else: extra

    Git.env(env: extra)
    |> Enum.map(fn {key, value} -> {String.to_charlist(key), String.to_charlist(value)} end)
  end

  defp put_env(state, @protocol_env, value) do
    if Regex.match?(@protocol_value, value) do
      {:success, %{state | protocol: value}}
    else
      {:failure, state}
    end
  end

  defp put_env(state, _var, _value), do: {:failure, state}

  ## Counting and finishing

  # The ref updates a push asks for arrive at the head of its stream, the same
  # pkt-lines the HTTP transport reads out of the request body.
  defp scan(%State{subcommand: "receive-pack", refs: nil} = state, data) do
    scan = state.scan <> data

    if byte_size(scan) >= @command_scan_bytes or String.contains?(scan, PktLine.flush()) do
      %{state | scan: <<>>, refs: PktLine.parse_commands(scan)}
    else
      %{state | scan: scan}
    end
  end

  defp scan(state, _data), do: state

  defp deny(state, message) do
    if state.span do
      Span.set_attributes(state.span, [{"error", true}, {"ssh.refusal", message}])
      Span.set_status(state.span, OpenTelemetry.status(:error, message))
    end

    :ssh_connection.send(state.cm, state.id, 1, "pinha: " <> message <> "\n")
    finish(state, 1)
  end

  defp finish(state, status) do
    if state.repo && state.subcommand == "receive-pack" && status == 0 do
      Maintenance.after_receive(state.repo)
    end

    report(state, status)

    :ssh_connection.send_eof(state.cm, state.id)
    :ssh_connection.exit_status(state.cm, state.id, status)
    :ssh_connection.close(state.cm, state.id)

    stop(%{state | finished: true})
  end

  # Neither half runs twice: `finish/2` marks the session reported, and a
  # session that never got as far as an exec has nothing to say.
  defp report(%State{started_at: nil}, _status), do: :ok

  defp report(state, status) do
    log(state, status)
    close_span(state, status)
  end

  defp stop(state) do
    close_port(state)
    {:stop, state.id, %{state | port: nil}}
  end

  # git may have exited already, which closes the port under us; writing to
  # one that is gone is the same as having nothing left to tell it.
  defp command(%State{port: port}, data) when is_port(port) do
    Port.command(port, data)
  catch
    :error, :badarg -> :ok
  end

  defp command(_state, _data), do: :ok

  defp close_port(%State{port: port}) when is_port(port) do
    Port.close(port)
  catch
    :error, :badarg -> :ok
  end

  defp close_port(_state), do: :ok

  defp log(state, status) do
    %{
      event: "request",
      transport: "ssh",
      method: "exec",
      path: nil,
      route: state.subcommand && "ssh/" <> state.subcommand,
      repo: state.repo && state.repo.name,
      rev: nil,
      git: state.subcommand || "none",
      user: state.user && state.user.id,
      peer: state.peer,
      status: status,
      duration_ms: duration(state),
      req_bytes: state.req_bytes,
      resp_bytes: state.resp_bytes,
      user_agent: nil
    }
    |> Widelog.put_refs(state.refs)
    |> put_git_stderr(state, status)
    |> Widelog.write()
  end

  # What git said before it failed goes on this session's line, not on the
  # server's stderr.
  defp put_git_stderr(line, %State{stderr_path: nil}, _status), do: line
  defp put_git_stderr(line, _state, 0), do: line

  defp put_git_stderr(line, state, _status) do
    case Git.read_stderr(state.stderr_path) do
      nil -> line
      stderr -> Map.put(line, :git_stderr, stderr)
    end
  end

  defp duration(%State{started_at: nil}), do: 0.0

  defp duration(%State{started_at: started_at}) do
    (System.monotonic_time() - started_at)
    |> System.convert_time_unit(:native, :microsecond)
    |> Kernel./(1000)
    |> Float.round(3)
  end

  defp close_span(%State{span: nil}, _status), do: :ok

  defp close_span(state, status) do
    Span.set_attributes(state.span, [
      {"status", status},
      {"req_bytes", state.req_bytes},
      {"resp_bytes", state.resp_bytes},
      {"refs", length(state.refs || [])}
    ])

    if status != 0 do
      stderr = state.stderr_path && Git.read_stderr(state.stderr_path)
      Span.set_attributes(state.span, [{"error", true}, {"git.stderr", stderr || ""}])
      Span.set_status(state.span, OpenTelemetry.status(:error, "git exited #{status}"))
    end

    Span.end_span(state.span)
    :ok
  end

  ## Housekeeping

  # A session that stops moving bytes in either direction is dropped, so a
  # client that vanished without closing its connection does not hold a git
  # process open behind it.
  defp arm(state) do
    if state.timer, do: Process.cancel_timer(state.timer)
    %{state | timer: Process.send_after(self(), :idle, @idle_timeout)}
  end

  defp peer(cm) do
    case :ssh.connection_info(cm, [:peer]) do
      [peer: {_name, {address, port}}] -> "#{:inet.ntoa(address)}:#{port}"
      _ -> nil
    end
  end
end
