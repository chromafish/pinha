defmodule PinhaWeb.MetricsTest do
  use PinhaWeb.ConnCase, async: false

  alias Pinha.Config
  alias Pinha.DiskUsage
  alias Pinha.Maintenance

  test "the metrics listener exposes Prometheus text", %{conn: conn} do
    create_repo!("demo")
    # Counters appear once a request has been served.
    get(conn, "/demo")

    response = scrape("/metrics")

    assert response =~ "HTTP/1.1 200 OK"
    assert response =~ "content-type: text/plain; version=0.0.4; charset=utf-8"
    assert response =~ "# TYPE http_requests_total counter"
    assert response =~ "# TYPE http_request_duration_ms histogram"
    assert response =~ "# TYPE repos_total gauge"
    assert response =~ "repos_total 1"
  end

  test "the public endpoint does not serve them", %{conn: conn} do
    # `/metrics` falls through to the repo routes, which need a user and find
    # no such repository, so nothing is exposed to a git client or a browser.
    assert conn |> get("/metrics") |> html_response(404) =~ "no such repository"
    assert build_conn() |> get("/metrics") |> redirected_to() == "/signin"
  end

  test "the metrics listener answers nothing else" do
    assert scrape("/") =~ "HTTP/1.1 404 Not Found"
    assert scrape("/demo") =~ "HTTP/1.1 404 Not Found"
  end

  test "repos_total tracks the repo root" do
    create_repo!("one")
    create_repo!("two")
    assert scrape() =~ "repos_total 2"

    :ok = Repos.delete("two")
    assert scrape() =~ "repos_total 1"
  end

  test "the background process caches disk usage per repo" do
    seed_repo!("demo", [%{message: "first", files: %{"a.txt" => "a\n"}}])
    DiskUsage.refresh()

    assert scrape() =~ ~r/repo_disk_bytes\{repo="demo"\} [1-9]\d*/
  end

  test "disk usage gauges are dropped for deleted repos" do
    create_repo!("demo")
    DiskUsage.refresh()
    assert scrape() =~ ~s(repo_disk_bytes{repo="demo"})

    :ok = Repos.delete("demo")
    DiskUsage.refresh()
    refute scrape() =~ ~s(repo_disk_bytes{repo="demo"})
  end

  test "maintenance repacks every repository without touching its refs" do
    repo = seed_repo!("demo", [%{message: "first", files: %{"a.txt" => "a\n"}}])
    before = Pinha.Git.log(repo, "main", limit: 1)

    assert :ok = Maintenance.run_all()
    assert Pinha.Git.log(repo, "main", limit: 1) == before
  end

  test "a push schedules background maintenance", %{user: user} do
    create_repo!("demo")
    work = tmp_dir!()
    clone = Path.join(work, "one")
    git!(work, ["clone", "--quiet", authenticated_url(user, "/demo.git"), clone])
    File.write!(Path.join(clone, "a.txt"), "a\n")
    git!(clone, ["add", "-A"])
    git!(clone, ["commit", "--quiet", "-m", "first"])
    git!(clone, ["push", "--quiet", "origin", "main"])

    await_background_tasks()
    {:ok, repo} = Repos.fetch("demo")
    assert [%{subject: "first"}] = Pinha.Git.log(repo, "main", limit: 1)
  end

  # A socket rather than an HTTP client, because what is being tested is that
  # the listener is a listener of its own, on its own port.
  defp scrape(path \\ "/metrics") do
    {:ok, socket} =
      :gen_tcp.connect(~c"127.0.0.1", Config.metrics_port(), [
        :binary,
        active: false,
        packet: :raw
      ])

    request = "GET #{path} HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n"
    :ok = :gen_tcp.send(socket, request)
    response = read(socket, "")
    :gen_tcp.close(socket)
    response
  end

  defp read(socket, acc) do
    case :gen_tcp.recv(socket, 0, 5_000) do
      {:ok, data} -> read(socket, acc <> data)
      {:error, :closed} -> acc
      {:error, reason} -> raise "reading the metrics response failed: #{inspect(reason)}"
    end
  end
end
