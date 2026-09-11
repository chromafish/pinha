defmodule PinhaWeb.Observability do
  @moduledoc """
  One canonical widelog line per HTTP request, plus the request metrics.

  The line goes to stdout as JSON, carrying the route, repo, rev, git
  protocol, authenticated user, status, duration, byte counts, and user agent;
  push lines also carry per-ref old and new tips, truncated after
  `:log_max_refs` refs.
  """

  alias Pinha.Metrics
  alias Pinha.Widelog

  @doc false
  defmacro __before_compile__(_env) do
    quote do
      defoverridable call: 2

      def call(conn, opts) do
        start_time = System.monotonic_time()
        conn = Plug.Conn.register_before_send(conn, &PinhaWeb.Observability.count_body/1)

        try do
          conn = super(conn, opts)
          PinhaWeb.Observability.finish(conn, start_time)
        catch
          kind, reason ->
            PinhaWeb.Observability.finish(%{conn | status: conn.status || 500}, start_time)
            :erlang.raise(kind, reason, __STACKTRACE__)
        end
      end
    end
  end

  @doc "Records metrics and writes the widelog line for a finished request."
  @spec finish(Plug.Conn.t(), integer()) :: Plug.Conn.t()
  def finish(conn, start_time) do
    duration_ms =
      System.convert_time_unit(System.monotonic_time() - start_time, :native, :microsecond) / 1000

    route = route(conn)
    status = conn.status || 0

    Metrics.inc("http_requests_total", [{"route", route}, {"status", to_string(status)}])
    Metrics.observe("http_request_duration_ms", duration_ms)

    Widelog.write(line(conn, route, duration_ms))

    conn
  end

  @doc "The widelog line as a map, before encoding."
  @spec line(Plug.Conn.t(), String.t(), float()) :: map()
  def line(conn, route, duration_ms) do
    %{
      ts: DateTime.utc_now() |> DateTime.to_iso8601(),
      transport: "http",
      method: conn.method,
      path: "/" <> Enum.join(conn.path_info, "/"),
      route: route,
      repo: repo_name(conn),
      rev: conn.path_params["rev"] || conn.path_params["id"],
      git: conn.private[:pinha_git_service] || "none",
      user: conn.assigns[:current_user] && conn.assigns.current_user.id,
      status: conn.status || 0,
      duration_ms: Float.round(duration_ms, 3),
      req_bytes: conn.private[:pinha_req_bytes] || request_bytes(conn),
      resp_bytes: conn.private[:pinha_resp_bytes] || 0,
      user_agent: header(conn, "user-agent")
    }
    |> put_refs(conn)
  end

  defp put_refs(line, conn), do: Widelog.put_refs(line, conn.private[:pinha_refs])

  @doc "The matched route pattern, or `unmatched` when nothing matched."
  @spec route(Plug.Conn.t()) :: String.t()
  def route(conn) do
    case Phoenix.Router.route_info(PinhaWeb.Router, conn.method, conn.path_info, conn.host) do
      %{route: route} -> route
      :error -> "unmatched"
    end
  end

  @doc "Counts a response body as it is sent, chunked or not."
  @spec count_body(Plug.Conn.t()) :: Plug.Conn.t()
  def count_body(conn), do: add_resp_bytes(conn, response_bytes(conn))

  # Clone URLs carry the `.git` suffix; the log names the repository.
  defp repo_name(conn) do
    case conn.path_params["repo"] do
      nil ->
        nil

      name ->
        case Pinha.Repos.normalize_name(name) do
          {:ok, normalized} -> normalized
          {:error, _} -> name
        end
    end
  end

  defp request_bytes(conn) do
    case header(conn, "content-length") do
      nil ->
        0

      value ->
        case Integer.parse(value) do
          {bytes, _} -> bytes
          :error -> 0
        end
    end
  end

  defp response_bytes(conn) do
    case conn.resp_body do
      body when is_binary(body) -> byte_size(body)
      nil -> 0
      body -> IO.iodata_length(body)
    end
  end

  defp header(conn, name) do
    case Plug.Conn.get_req_header(conn, name) do
      [value | _] -> value
      [] -> nil
    end
  end

  @doc "Adds bytes to the response byte counter carried on the connection."
  @spec add_resp_bytes(Plug.Conn.t(), non_neg_integer()) :: Plug.Conn.t()
  def add_resp_bytes(conn, bytes) do
    Plug.Conn.put_private(conn, :pinha_resp_bytes, (conn.private[:pinha_resp_bytes] || 0) + bytes)
  end

  @doc "Adds bytes to the request byte counter carried on the connection."
  @spec add_req_bytes(Plug.Conn.t(), non_neg_integer()) :: Plug.Conn.t()
  def add_req_bytes(conn, bytes) do
    Plug.Conn.put_private(conn, :pinha_req_bytes, (conn.private[:pinha_req_bytes] || 0) + bytes)
  end
end
