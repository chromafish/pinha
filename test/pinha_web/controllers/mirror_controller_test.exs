defmodule PinhaWeb.MirrorControllerTest do
  @moduledoc "The repository page's mirror pane and its controls."

  use PinhaWeb.ConnCase, async: false
  use Oban.Testing, repo: Pinha.Repo

  import Pinha.ProvidersFixtures

  alias Pinha.Mirroring
  alias Pinha.Mirroring.SyncWorker

  setup %{user: user} do
    repo = seed_repo!("demo", [%{message: "first", files: %{"a.txt" => "a\n"}}], user)
    account = github_account_fixture(user)
    stub_github(Map.new([token_route(), repository_route()]))

    %{repo: repo, account: account}
  end

  defp browser(conn), do: put_req_header(conn, "accept", "text/html,application/xhtml+xml")

  describe "the mirror pane" do
    test "shows the target, its state, and the controls", %{
      conn: conn,
      repo: repo,
      user: user,
      account: account
    } do
      mirror_fixture(repo, user, account)

      html = conn |> browser() |> get("/r/demo") |> html_response(200)

      assert html =~ "octo/demo"
      assert html =~ "https://github.test/octo/demo"
      assert html =~ "id=\"mirror-sync\""
      assert html =~ "id=\"mirror-disable\""
      assert html =~ "id=\"mirror-disconnect\""
      assert html =~ "Sync now"
    end

    test "shows a mirror as behind, and its latest failure to a writer", %{
      conn: conn,
      repo: repo,
      user: user,
      account: account
    } do
      mirror_fixture(repo, user, account,
        last_written_at: DateTime.utc_now(),
        last_failure: "GitHub answered 500",
        last_failed_at: DateTime.utc_now() |> DateTime.truncate(:second)
      )

      html = conn |> browser() |> get("/r/demo") |> html_response(200)

      assert html =~ "behind"
      assert html =~ "GitHub answered 500"
      assert html =~ "Retry"
    end

    test "offers a connect form to the owner, and none when nothing is configured", %{
      conn: conn
    } do
      html = conn |> browser() |> get("/r/demo") |> html_response(200)
      assert html =~ "id=\"mirror-connect-github\""

      put_github_env(app_id: nil)

      html = signed_in_conn() |> browser() |> get("/r/demo") |> html_response(200)
      refute html =~ "mirror-connect-github"
      refute html =~ "Connect mirror"
    end
  end

  describe "controls" do
    setup %{repo: repo, user: user, account: account} do
      %{mirror: mirror_fixture(repo, user, account)}
    end

    test "Sync now starts one sync", %{conn: conn, mirror: mirror} do
      conn = post(conn, "/r/demo/mirror/sync")

      assert redirected_to(conn) == "/r/demo"
      assert [job] = all_enqueued(worker: SyncWorker)
      assert job.args["mirror_id"] == mirror.id
      assert job.args["trigger"] == "manual"
    end

    test "Disable stops syncing, and Enable checks again before it starts", %{
      conn: conn,
      mirror: mirror
    } do
      conn = post(conn, "/r/demo/mirror/disable")
      assert redirected_to(conn) == "/r/demo"
      assert Mirroring.get(mirror.id).state == "disabled"
      assert all_enqueued(worker: SyncWorker) == []

      conn = signed_in_conn() |> post("/r/demo/mirror/enable")
      assert redirected_to(conn) == "/r/demo"
      assert Mirroring.get(mirror.id).state == "active"
      assert [_job] = all_enqueued(worker: SyncWorker)
    end

    test "Enable refuses a mirror whose connection check fails", %{
      conn: conn,
      repo: repo,
      mirror: mirror
    } do
      {:ok, _mirror} = Mirroring.disable(mirror)
      other = user_fixture()
      {:ok, _repo} = Pinha.Repos.set_owner(repo.name, other.username)

      conn = post(conn, "/r/demo/mirror/enable")

      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "stays disabled"
      assert Mirroring.get(mirror.id).state == "disabled"
      assert all_enqueued(worker: SyncWorker) == []
    end

    test "Disconnect removes the mirror", %{conn: conn, mirror: mirror} do
      conn = delete(conn, "/r/demo/mirror")

      assert redirected_to(conn) == "/r/demo"
      assert Mirroring.get(mirror.id) == nil
    end

    test "someone who cannot write the repository cannot touch the mirror", %{mirror: mirror} do
      stranger = user_fixture()
      conn = build_conn() |> log_in_user(stranger) |> browser()

      assert conn |> post("/r/demo/mirror/sync") |> html_response(403)
      assert Mirroring.get(mirror.id).state == "active"
    end
  end

  describe "connecting" do
    test "sends the owner to the provider", %{conn: conn} do
      stub_github(%{
        {"GET", "/users/octo/installation"} => %{
          "id" => 99,
          "account" => %{"id" => 4711, "login" => "octo", "type" => "User"}
        }
      })

      conn =
        post(conn, "/r/demo/mirror", %{
          "provider" => "github",
          "account" => "octo",
          "name" => "demo",
          "mode" => "new"
        })

      assert redirected_to(conn) =~ "https://github.test/login/oauth/authorize"
    end

    test "sends the owner to install the app when it is not installed", %{conn: conn} do
      stub_github(%{
        {"GET", "/users/octo/installation"} =>
          &(&1 |> Plug.Conn.put_status(404) |> Req.Test.json(%{"message" => "Not Found"}))
      })

      conn =
        post(conn, "/r/demo/mirror", %{
          "provider" => "github",
          "account" => "octo",
          "name" => "demo",
          "mode" => "new"
        })

      assert redirected_to(conn) =~ "https://github.test/apps/pinha-test/installations/new"
    end

    test "an existing target must be confirmed first", %{conn: conn} do
      conn =
        post(conn, "/r/demo/mirror", %{
          "provider" => "github",
          "account" => "octo",
          "name" => "demo",
          "mode" => "existing"
        })

      assert redirected_to(conn) == "/r/demo"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Confirm"
    end

    test "only the owner connects one", %{repo: repo} do
      admin = user_fixture(%{admin: true})
      conn = build_conn() |> log_in_user(admin) |> browser()

      conn =
        post(conn, "/r/demo/mirror", %{
          "provider" => "github",
          "account" => "octo",
          "name" => "demo",
          "mode" => "new"
        })

      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "owner"
      assert Mirroring.for_repo(repo) == nil
    end
  end
end
