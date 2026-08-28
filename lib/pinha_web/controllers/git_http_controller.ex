defmodule PinhaWeb.GitHttpController do
  @moduledoc """
  Smart HTTP transport endpoints.

  `jj git clone`, `jj git fetch`, and `jj git push` use these same endpoints:
  the server only ever moves packs and refs, and never rewrites the commits a
  client sends, so `change-id` trailers survive a round trip untouched.
  """

  use PinhaWeb, :controller

  alias Pinha.Git.PktLine
  alias Pinha.Git.Transport
  alias Pinha.Maintenance
  alias Pinha.Metrics
  alias Pinha.Repos
  alias PinhaWeb.Observability

  require Logger

  @command_scan_bytes 65_536
  @read_chunk 1_000_000

  def info_refs(conn, %{"repo" => name} = params) do
    service = params["service"]

    with {:ok, repo} <- Repos.fetch(name),
         true <- Transport.service?(service) do
      conn = put_private(conn, :pinha_git_service, Transport.subcommand(service))

      case Transport.advertise(repo.dir, service, env: protocol_env(conn)) do
        {:ok, body} ->
          conn
          |> no_cache()
          |> put_resp_header("content-type", "application/x-#{service}-advertisement")
          |> send_resp(200, body)

        {:error, reason} ->
          Logger.error("advertise failed for #{repo.name}: #{inspect(reason)}")
          send_resp(conn, 500, "advertisement failed\n")
      end
    else
      false -> send_resp(conn, 403, "only the smart HTTP protocol is supported\n")
      {:error, :invalid_name} -> send_resp(conn, 400, "invalid repository name\n")
      {:error, :invalid_repo} -> send_resp(conn, 500, "not a valid bare repository\n")
      {:error, :not_found} -> send_resp(conn, 404, "no such repository\n")
    end
  end

  def upload_pack(conn, %{"repo" => name}), do: rpc(conn, name, "git-upload-pack")

  def receive_pack(conn, %{"repo" => name}), do: rpc(conn, name, "git-receive-pack")

  defp rpc(conn, name, service) do
    case Repos.fetch(name) do
      {:ok, repo} ->
        conn = put_private(conn, :pinha_git_service, Transport.subcommand(service))
        input = tmp_path()

        try do
          case stash_body(conn, input) do
            {:ok, conn} ->
              conn = conn |> record(repo, service, input) |> stream(repo, service, input)
              if service == "git-receive-pack", do: Maintenance.after_receive(repo)
              conn

            {:error, reason} ->
              Logger.error("reading #{service} body failed: #{inspect(reason)}")
              send_resp(conn, 400, "could not read request body\n")
          end
        after
          File.rm(input)
        end

      {:error, :invalid_name} ->
        send_resp(conn, 400, "invalid repository name\n")

      {:error, :invalid_repo} ->
        send_resp(conn, 500, "not a valid bare repository\n")

      {:error, :not_found} ->
        send_resp(conn, 404, "no such repository\n")
    end
  end

  defp stream(conn, repo, service, input) do
    conn =
      conn
      |> no_cache()
      |> put_resp_header("content-type", "application/x-#{service}-result")
      |> send_chunked(200)

    case Transport.rpc(repo.dir, service, input, [env: protocol_env(conn)], conn, &send_data/2) do
      {:ok, conn, 0} ->
        conn

      {:ok, conn, status} ->
        Logger.error("#{service} exited with #{status} for #{repo.name}")
        conn

      {:error, reason, conn} ->
        Logger.error("#{service} failed for #{repo.name}: #{inspect(reason)}")
        conn
    end
  end

  defp send_data(conn, data) do
    case chunk(conn, data) do
      {:ok, conn} -> Observability.add_resp_bytes(conn, byte_size(data))
      {:error, _reason} -> conn
    end
  end

  # Counts the request and, for a push, remembers the ref updates it asks for
  # so the widelog line and the metrics can carry them.
  defp record(conn, repo, "git-upload-pack", _input) do
    Metrics.inc("git_fetches_total", [{"repo", repo.name}])
    conn
  end

  defp record(conn, repo, "git-receive-pack", input) do
    commands =
      case File.open(input, [:read, :binary, :raw], &:file.read(&1, @command_scan_bytes)) do
        {:ok, {:ok, head}} -> PktLine.parse_commands(head)
        _ -> []
      end

    Metrics.inc("git_pushes_total", [{"repo", repo.name}])
    Metrics.inc("git_ref_updates_total", [{"repo", repo.name}], length(commands))
    put_private(conn, :pinha_refs, commands)
  end

  # Writes the request body to a file so the child process sees a real EOF,
  # inflating it first when the client gzipped the request.
  defp stash_body(conn, path) do
    gzip? = Enum.any?(get_req_header(conn, "content-encoding"), &(&1 =~ "gzip"))
    file = File.open!(path, [:write, :binary, :raw])
    zstream = if gzip?, do: init_inflate(), else: nil

    try do
      copy_body(conn, file, zstream)
    after
      File.close(file)
      if zstream, do: close_inflate(zstream)
    end
  end

  defp copy_body(conn, file, zstream) do
    case read_body(conn, length: @read_chunk, read_length: @read_chunk) do
      {:ok, chunk, conn} ->
        :ok = write(file, zstream, chunk)
        {:ok, Observability.add_req_bytes(conn, byte_size(chunk))}

      {:more, chunk, conn} ->
        :ok = write(file, zstream, chunk)
        copy_body(Observability.add_req_bytes(conn, byte_size(chunk)), file, zstream)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp write(file, nil, data), do: :file.write(file, data)
  defp write(file, zstream, data), do: :file.write(file, :zlib.inflate(zstream, data))

  defp init_inflate do
    zstream = :zlib.open()
    :zlib.inflateInit(zstream, 47)
    zstream
  end

  defp close_inflate(zstream) do
    :zlib.inflateEnd(zstream)
    :zlib.close(zstream)
  catch
    :error, _ -> :ok
  end

  # Protocol v2 is opt-in per request: the client asks for it with a header,
  # and git reads it from the environment.
  defp protocol_env(conn) do
    case get_req_header(conn, "git-protocol") do
      [value | _] ->
        if Regex.match?(~r/\A[a-zA-Z0-9=.:,\-]{1,100}\z/, value) do
          [{"GIT_PROTOCOL", value}]
        else
          []
        end

      [] ->
        []
    end
  end

  defp no_cache(conn) do
    conn
    |> put_resp_header("expires", "Fri, 01 Jan 1980 00:00:00 GMT")
    |> put_resp_header("pragma", "no-cache")
    |> put_resp_header("cache-control", "no-cache, max-age=0, must-revalidate")
  end

  defp tmp_path do
    Path.join(
      System.tmp_dir!(),
      "pinha-rpc-" <> Base.encode16(:crypto.strong_rand_bytes(12), case: :lower)
    )
  end
end
