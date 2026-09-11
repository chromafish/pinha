defmodule PinhaWeb.ObservabilityTest do
  use PinhaWeb.ConnCase, async: false

  alias Pinha.Metrics
  alias PinhaWeb.Observability

  test "the widelog line carries the canonical request fields", %{conn: conn} do
    seed_repo!("demo", [%{message: "first", files: %{"a.txt" => "a\n"}}])

    conn = conn |> put_req_header("user-agent", "git/2.50.1") |> get("/demo/tree/main/a.txt")
    line = Observability.line(conn, Observability.route(conn), 12.5)

    assert line.method == "GET"
    assert line.route == "/:repo/tree/:rev/*path"
    assert line.repo == "demo"
    assert line.rev == "main"
    assert line.status == 200
    assert line.duration_ms == 12.5
    assert line.user_agent == "git/2.50.1"
    assert line.resp_bytes > 0
    assert line.git == "none"
    assert {:ok, _, _} = DateTime.from_iso8601(line.ts)
    assert is_binary(Jason.encode!(line))
  end

  test "git RPC lines name the protocol and the pushed refs" do
    create_repo!("demo")
    before = counter(~s(git_ref_updates_total{repo="demo"}))
    new = String.duplicate("a", 40)
    old = String.duplicate("0", 40)

    # A command list with no pack is enough to exercise command parsing and
    # the push half of the widelog line; real pushes are covered end to end in
    # PinhaWeb.GitHttpControllerTest.
    body =
      Pinha.Git.PktLine.encode("#{old} #{new} refs/heads/main\0report-status\n") <>
        Pinha.Git.PktLine.encode("#{old} #{new} refs/tags/v1\n") <>
        Pinha.Git.PktLine.flush()

    conn =
      signed_in_conn()
      |> put_req_header("content-type", "application/x-git-receive-pack-request")
      |> post("/demo.git/git-receive-pack", body)

    line = Observability.line(conn, Observability.route(conn), 1.0)

    assert line.git == "receive-pack"
    assert line.repo == "demo"

    assert line.refs == [
             %{ref: "refs/heads/main", old: old, new: new},
             %{ref: "refs/tags/v1", old: old, new: new}
           ]

    assert line.refs_total == 2
    assert line.refs_truncated == 0
    assert line.req_bytes == byte_size(body)
    assert counter(~s(git_ref_updates_total{repo="demo"})) == before + 2
  end

  # Metric counters live for the whole test run, so assertions compare deltas.
  defp counter(series) do
    case Regex.run(~r/^#{Regex.escape(series)} (\d+)$/m, IO.iodata_to_binary(Metrics.render())) do
      [_, value] -> String.to_integer(value)
      nil -> 0
    end
  end

  test "the route is reported even when nothing matched", %{conn: conn} do
    conn = get(conn, "/demo/nope/deeper")
    assert Observability.route(conn) == "unmatched"
  end

  test "request metrics are recorded per route and status", %{conn: conn} do
    create_repo!("demo")
    get(conn, "/demo")

    metrics = IO.iodata_to_binary(Metrics.render())
    assert metrics =~ ~s(http_requests_total{route="/:repo",status="200"})
    assert metrics =~ "http_request_duration_ms_bucket{le=\"+Inf\"}"
    assert metrics =~ "http_request_duration_ms_count"
  end
end
