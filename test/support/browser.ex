defmodule Pinha.Browser do
  @moduledoc """
  A headless Chromium driven over the DevTools protocol.

  CDP's `WebAuthn` domain provides a virtual authenticator, which is what lets
  the suite run the passkey ceremonies against a real page.

  Set `PINHA_TEST_BROWSER` to choose a Chromium binary. Otherwise the usual
  install locations are searched, including Playwright's cache.
  """

  use GenServer

  @candidates [
    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
    "/Applications/Chromium.app/Contents/MacOS/Chromium"
  ]

  @executables ~w(chromium chromium-browser google-chrome google-chrome-stable)

  @call_timeout 30_000

  ## Finding one

  @doc "The Chromium this machine has, or `:error`."
  @spec find() :: {:ok, String.t()} | :error
  def find do
    [
      System.get_env("PINHA_TEST_BROWSER"),
      playwright_shell(),
      Enum.find(@candidates, &executable?/1),
      Enum.find_value(@executables, &System.find_executable/1)
    ]
    |> Enum.find(&executable?/1)
    |> case do
      nil -> :error
      path -> {:ok, path}
    end
  end

  @doc "What to tell whoever is missing a browser."
  @spec install_hint() :: String.t()
  def install_hint do
    "no Chromium found: install one with `npx playwright install " <>
      "chromium-headless-shell`, or point PINHA_TEST_BROWSER at a binary you have"
  end

  # Playwright keeps a headless shell per build; the newest one will do.
  defp playwright_shell do
    base =
      case :os.type() do
        {:unix, :darwin} -> Path.expand("~/Library/Caches/ms-playwright")
        _ -> Path.expand("~/.cache/ms-playwright")
      end

    (base <> "/chromium_headless_shell-*/chrome-headless-shell-*/chrome-headless-shell")
    |> Path.wildcard()
    |> Enum.sort()
    |> List.last()
  end

  defp executable?(nil), do: false

  defp executable?(path),
    do: File.regular?(path) and File.stat!(path).access in [:read, :read_write]

  ## Driving one

  @doc "Starts a browser and connects to its debugging endpoint."
  @spec start_link(String.t()) :: GenServer.on_start()
  def start_link(executable), do: GenServer.start_link(__MODULE__, executable)

  @doc "Closes the websocket and the browser behind it."
  @spec stop(pid()) :: :ok
  def stop(pid), do: GenServer.stop(pid, :normal, @call_timeout)

  @doc """
  Sends one CDP command and returns its result.

  Every command carries an id and its reply is matched on that, so an event
  arriving mid-call is discarded rather than mistaken for the answer.
  """
  @spec call!(pid(), String.t(), map(), String.t() | nil) :: map()
  def call!(pid, method, params \\ %{}, session_id \\ nil) do
    case GenServer.call(pid, {:command, method, params, session_id}, @call_timeout) do
      {:ok, result} -> result
      {:error, error} -> raise "CDP #{method} failed: #{inspect(error)}"
    end
  end

  ## Server

  @impl true
  def init(executable) do
    # Trapping exits is what gets terminate/2 run, and terminate/2 is the only
    # thing that reaps the browser: closing the port leaves it running.
    Process.flag(:trap_exit, true)

    profile = Path.join(System.tmp_dir!(), "pinha-cdp-#{System.unique_integer([:positive])}")
    File.mkdir_p!(profile)

    # Chromium talks on stderr whatever the log level, and a refused assertion
    # is a normal outcome here, so its noise is dropped rather than mixed into
    # the suite's output. `exec` keeps the port's os_pid pointing at the
    # browser rather than at a shell wrapping it.
    command =
      [
        executable,
        "--headless",
        "--disable-gpu",
        "--no-first-run",
        "--no-default-browser-check",
        "--remote-debugging-port=0",
        "--user-data-dir=#{profile}",
        "about:blank"
      ]
      |> Enum.map_join(" ", &shell_quote/1)

    port =
      Port.open({:spawn_executable, "/bin/sh"}, [
        :binary,
        :exit_status,
        args: ["-c", "exec #{command} 2>/dev/null"]
      ])

    with {:ok, url} <- await_endpoint(profile),
         {:ok, state} <- connect(url) do
      File.rm_rf(profile)
      {:ok, Map.merge(state, %{port: port, pending: %{}})}
    else
      {:error, reason} ->
        File.rm_rf(profile)
        {:stop, reason}
    end
  end

  @impl true
  def terminate(_reason, state) do
    Mint.HTTP.close(state.conn)

    case Port.info(state.port, :os_pid) do
      {:os_pid, os_pid} ->
        System.cmd("kill", ["-9", Integer.to_string(os_pid)], stderr_to_stdout: true)
        Port.close(state.port)

      nil ->
        :ok
    end

    :ok
  end

  @impl true
  def handle_call({:command, method, params, session_id}, from, state) do
    id = System.unique_integer([:positive, :monotonic])

    payload =
      %{id: id, method: method, params: params}
      |> then(&if session_id, do: Map.put(&1, :sessionId, session_id), else: &1)
      |> Jason.encode!()

    {:ok, websocket, data} = Mint.WebSocket.encode(state.websocket, {:text, payload})
    {:ok, conn} = Mint.WebSocket.stream_request_body(state.conn, state.ref, data)

    {:noreply,
     %{state | conn: conn, websocket: websocket, pending: Map.put(state.pending, id, from)}}
  end

  @impl true
  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    {:stop, {:browser_exited, status}, state}
  end

  def handle_info(message, state) do
    case Mint.WebSocket.stream(state.conn, message) do
      {:ok, conn, responses} ->
        {:noreply, dispatch(%{state | conn: conn}, responses)}

      {:error, conn, reason, _responses} ->
        {:stop, {:connection_failed, reason}, %{state | conn: conn}}

      :unknown ->
        {:noreply, state}
    end
  end

  # A CDP reply carries the id of the command it answers; everything else on
  # the socket is an event nothing here has asked for.
  defp dispatch(state, responses) do
    for({:data, _ref, data} <- responses, do: data)
    |> Enum.reduce(state, fn data, state ->
      {:ok, websocket, frames} = Mint.WebSocket.decode(state.websocket, data)

      state =
        Enum.reduce(frames, %{state | websocket: websocket}, fn
          {:text, text}, state -> reply(state, Jason.decode!(text))
          _frame, state -> state
        end)

      state
    end)
  end

  defp reply(state, %{"id" => id} = frame) do
    case Map.pop(state.pending, id) do
      {nil, _pending} ->
        state

      {from, pending} ->
        answer =
          case frame do
            %{"error" => error} -> {:error, error}
            %{"result" => result} -> {:ok, result}
          end

        GenServer.reply(from, answer)
        %{state | pending: pending}
    end
  end

  defp reply(state, _event), do: state

  defp shell_quote(argument), do: "'" <> String.replace(argument, "'", ~S('\'')) <> "'"

  ## Connecting

  # Chromium writes the port it settled on into the profile once it is ready.
  defp await_endpoint(profile, attempts \\ 200) do
    file = Path.join(profile, "DevToolsActivePort")

    case File.read(file) do
      {:ok, contents} ->
        case String.split(String.trim(contents), "\n") do
          [port, path] -> {:ok, "ws://127.0.0.1:#{port}#{path}"}
          _ -> retry_endpoint(profile, attempts)
        end

      {:error, _reason} ->
        retry_endpoint(profile, attempts)
    end
  end

  defp retry_endpoint(_profile, 0), do: {:error, :no_debugging_port}

  defp retry_endpoint(profile, attempts) do
    Process.sleep(50)
    await_endpoint(profile, attempts - 1)
  end

  defp connect(url) do
    %URI{host: host, port: port, path: path} = URI.parse(url)

    with {:ok, conn} <- Mint.HTTP.connect(:http, host, port, protocols: [:http1]),
         {:ok, conn, ref} <- Mint.WebSocket.upgrade(:ws, conn, path, []),
         {:ok, conn, websocket} <- await_upgrade(conn, ref) do
      {:ok, %{conn: conn, websocket: websocket, ref: ref}}
    else
      {:error, reason} -> {:error, reason}
      {:error, _conn, reason} -> {:error, reason}
    end
  end

  defp await_upgrade(conn, ref) do
    receive do
      message ->
        {:ok, conn, responses} = Mint.WebSocket.stream(conn, message)

        case Enum.find(responses, &match?({:status, ^ref, _}, &1)) do
          nil ->
            await_upgrade(conn, ref)

          {:status, ^ref, status} ->
            headers =
              Enum.flat_map(responses, fn
                {:headers, ^ref, headers} -> headers
                _other -> []
              end)

            Mint.WebSocket.new(conn, ref, status, headers)
        end
    after
      10_000 -> {:error, :upgrade_timeout}
    end
  end
end
