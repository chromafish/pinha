defmodule PinhaWeb.MetricsTest do
  use PinhaWeb.ConnCase, async: false

  alias Pinha.DiskUsage
  alias Pinha.Maintenance

  test "GET /metrics exposes Prometheus text", %{conn: conn} do
    create_repo!("demo")
    # Counters appear once a request has been served.
    get(conn, "/demo")

    conn = get(build_conn(), "/metrics")
    body = response(conn, 200)

    assert get_resp_header(conn, "content-type") == ["text/plain; version=0.0.4; charset=utf-8"]
    assert body =~ "# TYPE http_requests_total counter"
    assert body =~ "# TYPE http_request_duration_ms histogram"
    assert body =~ "# TYPE repos_total gauge"
    assert body =~ "repos_total 1"
  end

  test "repos_total tracks the repo root", %{conn: conn} do
    create_repo!("one")
    create_repo!("two")
    assert conn |> get("/metrics") |> response(200) =~ "repos_total 2"

    :ok = Repos.delete("two")
    assert build_conn() |> get("/metrics") |> response(200) =~ "repos_total 1"
  end

  test "the background process caches disk usage per repo", %{conn: conn} do
    seed_repo!("demo", [%{message: "first", files: %{"a.txt" => "a\n"}}])
    DiskUsage.refresh()

    assert conn |> get("/metrics") |> response(200) =~ ~r/repo_disk_bytes\{repo="demo"\} [1-9]\d*/
  end

  test "disk usage gauges are dropped for deleted repos", %{conn: conn} do
    create_repo!("demo")
    DiskUsage.refresh()
    assert conn |> get("/metrics") |> response(200) =~ ~s(repo_disk_bytes{repo="demo"})

    :ok = Repos.delete("demo")
    DiskUsage.refresh()
    refute build_conn() |> get("/metrics") |> response(200) =~ ~s(repo_disk_bytes{repo="demo"})
  end

  test "maintenance repacks every repository without touching its refs" do
    repo = seed_repo!("demo", [%{message: "first", files: %{"a.txt" => "a\n"}}])
    before = Pinha.Git.log(repo, "main", limit: 1)

    assert :ok = Maintenance.run_all()
    assert Pinha.Git.log(repo, "main", limit: 1) == before
  end

  test "a push schedules background maintenance" do
    create_repo!("demo")
    work = tmp_dir!()
    clone = Path.join(work, "one")
    git!(work, ["clone", "--quiet", base_url() <> "/demo.git", clone])
    File.write!(Path.join(clone, "a.txt"), "a\n")
    git!(clone, ["add", "-A"])
    git!(clone, ["commit", "--quiet", "-m", "first"])
    git!(clone, ["push", "--quiet", "origin", "main"])

    await_background_tasks()
    {:ok, repo} = Repos.fetch("demo")
    assert [%{subject: "first"}] = Pinha.Git.log(repo, "main", limit: 1)
  end
end
