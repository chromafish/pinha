defmodule Pinha.Git.Transport do
  @moduledoc """
  Smart HTTP transport: ref advertisement plus the `upload-pack` and
  `receive-pack` RPCs.

  The RPC child reads the request body from a file so it sees a real EOF on
  stdin, and its stdout is streamed back to the client as it arrives.
  """

  alias Pinha.Config
  alias Pinha.Git
  alias Pinha.Git.PktLine

  require Logger
  require OpenTelemetry.Tracer, as: Tracer

  @idle_timeout 300_000

  @doc "Ref advertisement body for `GET /:repo/info/refs?service=...`."
  @spec advertise(String.t(), String.t(), keyword()) :: {:ok, binary()} | {:error, term()}
  def advertise(dir, service, opts \\ []) do
    args = [subcommand(service), "--stateless-rpc", "--http-backend-info-refs", "."]

    stderr = Git.stderr_path()

    try do
      case System.cmd("/bin/sh", Git.shell_args(Config.git_bin(), args),
             cd: dir,
             env: [{Git.stderr_var(), stderr} | Git.env(opts)],
             stderr_to_stdout: false
           ) do
        {out, 0} ->
          {:ok, PktLine.encode("# service=#{service}\n") <> PktLine.flush() <> out}

        {_out, code} ->
          Git.log_failure(dir, args, code, Git.read_stderr(stderr))
          {:error, {:exit, code}}
      end
    after
      File.rm(stderr)
    end
  end

  @doc """
  Runs an RPC with stdin read from `input_path`, invoking `on_chunk` for each
  block of output.

  `on_chunk` receives `(acc, data)` and returns the next accumulator. The
  child's stderr is captured and returned with the exit status, so the caller
  can put it on the request's own log line rather than leaking it to the
  server's stderr.
  """
  @spec rpc(String.t(), String.t(), String.t(), keyword(), acc, (acc, binary() -> acc)) ::
          {:ok, acc, integer(), String.t() | nil} | {:error, term(), acc}
        when acc: term()
  def rpc(dir, service, input_path, opts, acc, on_chunk) do
    Tracer.with_span "git #{subcommand(service)}",
                     %{attributes: Git.span_attributes(dir, subcommand(service), [service])} do
      run_rpc(dir, service, input_path, opts, acc, on_chunk)
    end
  end

  defp run_rpc(dir, service, input_path, opts, acc, on_chunk) do
    stderr = Git.stderr_path()

    command =
      "exec #{shell_quote(Config.git_bin())} #{subcommand(service)} --stateless-rpc #{shell_quote(dir)} " <>
        "< #{shell_quote(input_path)} 2>\"$#{Git.stderr_var()}\""

    port =
      Port.open({:spawn_executable, "/bin/sh"}, [
        :binary,
        :exit_status,
        :hide,
        args: ["-c", command],
        cd: dir,
        env:
          port_env(
            [{Git.stderr_var(), stderr} | Keyword.get(opts, :env, [])]
            |> then(&Keyword.put(opts, :env, &1))
          )
      ])

    try do
      case stream(port, acc, on_chunk) do
        {:ok, acc, 0} ->
          {:ok, acc, 0, nil}

        {:ok, acc, status} ->
          message = Git.read_stderr(stderr)
          Git.record_failure(status, message)
          {:ok, acc, status, message}

        {:error, reason, acc} ->
          Tracer.set_status(OpenTelemetry.status(:error, "transport failed"))
          {:error, reason, acc}
      end
    after
      File.rm(stderr)
    end
  end

  defp stream(port, acc, on_chunk) do
    receive do
      {^port, {:data, data}} ->
        stream(port, on_chunk.(acc, data), on_chunk)

      {^port, {:exit_status, status}} ->
        {:ok, acc, status}
    after
      @idle_timeout ->
        Logger.error("git rpc timed out after #{@idle_timeout}ms")
        close(port)
        {:error, :timeout, acc}
    end
  end

  defp close(port) do
    Port.close(port)
  catch
    :error, :badarg -> :ok
  end

  defp port_env(opts) do
    Git.env(opts)
    |> Enum.map(fn {key, value} -> {String.to_charlist(key), String.to_charlist(value)} end)
  end

  @doc "Maps `git-upload-pack` to the `upload-pack` subcommand."
  @spec subcommand(String.t()) :: String.t()
  def subcommand("git-upload-pack"), do: "upload-pack"
  def subcommand("git-receive-pack"), do: "receive-pack"

  @doc "True for the two services the smart HTTP transport exposes."
  @spec service?(String.t()) :: boolean()
  def service?(service), do: service in ["git-upload-pack", "git-receive-pack"]

  defp shell_quote(value), do: "'" <> String.replace(value, "'", "'\\''") <> "'"
end
