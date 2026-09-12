defmodule Pinha.Mirroring.ConnectTest do
  @moduledoc "What connecting a GitHub target verifies before a mirror exists."

  use Pinha.DataCase, async: false
  use Pinha.RepoCase, async: false
  use Oban.Testing, repo: Pinha.Repo

  import Pinha.ProvidersFixtures

  alias Pinha.Mirroring
  alias Pinha.Mirroring.ConnectHandler
  alias Pinha.Mirroring.SyncWorker
  alias Pinha.Providers.Authorizations
  alias Pinha.Providers.GitHub

  setup do
    user = user_fixture()
    account = github_account_fixture(user)
    repo = seed_repo!("demo", [%{message: "first", files: %{"a.txt" => "a\n"}}], user)

    %{user: user, account: account, repo: repo}
  end

  defp connect(user, params, routes) do
    stub_github(
      Map.merge(
        %{
          {"POST", "/login/oauth/access_token"} => %{"access_token" => "gho_usertoken"},
          {"DELETE", "/applications/Iv1.testclient/token"} => &Plug.Conn.send_resp(&1, 204, ""),
          {"GET", "/user"} => %{"id" => 4711, "login" => "octo"},
          {"GET", "/users/octo/installation"} => installation()
        },
        routes
      )
    )

    {:ok, _url} = Authorizations.start(user, GitHub, ConnectHandler, params)
    [%{state_hash: hash}] = Pinha.Repo.all(Pinha.Providers.Authorization)
    state = state_for(hash, params)

    Authorizations.finish(GitHub, user, %{"state" => state, "code" => "abc"})
  end

  # `start/5` keeps only the hash, so the suite runs the callback with a state
  # it writes itself.
  defp state_for(_hash, _params) do
    state = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

    Pinha.Repo.update_all(Pinha.Providers.Authorization,
      set: [state_hash: :crypto.hash(:sha256, state)]
    )

    state
  end

  defp installation(type \\ "User") do
    %{"id" => 99, "account" => %{"id" => 4711, "login" => "octo", "type" => type}}
  end

  defp params(repo, extra \\ %{}) do
    Map.merge(
      %{
        "repo_name" => repo.name,
        "repo_id" => repo.id,
        "return_to" => "/r/#{repo.name}",
        "account" => "octo",
        "name" => "demo",
        "mode" => "new",
        "private" => true
      },
      extra
    )
  end

  test "creates the target, records the mirror, and syncs right away", %{
    user: user,
    repo: repo
  } do
    # The stub runs in the process the handler runs in, not in the test's.
    test_pid = self()

    routes = %{
      {"POST", "/user/repos"} => fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:created, Jason.decode!(body)})

        Req.Test.json(conn, %{
          "id" => 1234,
          "full_name" => "octo/demo",
          "html_url" => "https://github.test/octo/demo"
        })
      end,
      {"POST", "/app/installations/99/access_tokens"} => %{"token" => "ghs_token"}
    }

    assert {:ok, %{message: message, to: "/r/demo"}} = connect(user, params(repo), routes)
    assert message =~ "Mirroring to octo/demo"

    assert_received {:created, created}
    assert created["name"] == "demo"
    assert created["private"] == true
    assert created["has_issues"] == false
    assert created["has_wiki"] == false

    mirror = Mirroring.for_repo(repo)
    assert mirror.state == "active"
    assert mirror.target_id == "1234"
    assert mirror.installation_id == "99"
    assert mirror.target_account_type == "user"
    assert mirror.connected_by_user_id == user.id

    assert [job] = all_enqueued(worker: SyncWorker)
    assert job.args["trigger"] == "connected"
  end

  test "leaves a target the installation cannot reach awaiting access", %{
    user: user,
    repo: repo
  } do
    routes = %{
      {"GET", "/repos/octo/demo"} => %{
        "id" => 1234,
        "full_name" => "octo/demo",
        "html_url" => "https://github.test/octo/demo",
        "permissions" => %{"admin" => true}
      },
      {"POST", "/app/installations/99/access_tokens"} =>
        &(&1
          |> Plug.Conn.put_status(422)
          |> Req.Test.json(%{"message" => "There is at least one repository out of reach"}))
    }

    assert {:ok, %{message: message}} =
             connect(user, params(repo, %{"mode" => "existing"}), routes)

    assert message =~ "cannot reach it yet"
    assert Mirroring.for_repo(repo).state == "awaiting_access"
    assert all_enqueued(worker: SyncWorker) == []
  end

  test "refuses an existing target the user does not administer", %{user: user, repo: repo} do
    routes = %{
      {"GET", "/repos/octo/demo"} => %{
        "id" => 1234,
        "full_name" => "octo/demo",
        "html_url" => "https://github.test/octo/demo",
        "permissions" => %{"admin" => false}
      }
    }

    assert {:error, %{message: message}} =
             connect(user, params(repo, %{"mode" => "existing"}), routes)

    assert message =~ "admin access"
    assert Mirroring.for_repo(repo) == nil
  end

  test "refuses a personal target that is not the authorizing user's own", %{
    user: user,
    repo: repo
  } do
    routes = %{
      {"GET", "/users/someone-else/installation"} => %{
        "id" => 99,
        "account" => %{"id" => 5, "login" => "someone-else", "type" => "User"}
      }
    }

    assert {:error, %{message: message}} =
             connect(user, params(repo, %{"account" => "someone-else"}), routes)

    assert message =~ "your own account"
    assert Mirroring.for_repo(repo) == nil
  end

  test "refuses when the user authorized as another GitHub account", %{user: user, repo: repo} do
    routes = %{{"GET", "/user"} => %{"id" => 9999, "login" => "someone-else"}}

    assert {:error, %{message: message}} = connect(user, params(repo), routes)

    assert message =~ "not the linked account"
    assert Mirroring.for_repo(repo) == nil
  end

  test "refuses once the repository has changed hands", %{user: user, repo: repo} do
    other = user_fixture()
    {:ok, _repo} = Pinha.Repos.set_owner(repo.name, other.username)

    assert {:error, %{message: message}} = connect(user, params(repo), %{})
    assert message =~ "owner"
    assert Mirroring.for_repo(repo) == nil
  end

  test "an installation an owner must approve says so", %{repo: repo} do
    assert {:error, %{message: message}} =
             ConnectHandler.handle_incomplete(%{
               provider: GitHub,
               params: params(repo),
               callback: %{"setup_action" => "request"}
             })

    assert message =~ "must approve"
  end
end
