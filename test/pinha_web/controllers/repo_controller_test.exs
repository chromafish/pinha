defmodule PinhaWeb.RepoControllerTest do
  use PinhaWeb.ConnCase, async: false

  defp browser(conn), do: put_req_header(conn, "accept", "text/html,application/xhtml+xml")

  describe "GET /" do
    test "lists repositories with their description and head commit", %{conn: conn} do
      seed_repo!("demo", [%{message: "first commit", files: %{"a.txt" => "a\n"}}])
      {:ok, repo} = Repos.fetch("demo")
      File.write!(Path.join(repo.dir, "description"), "the demo repo\n")

      html = conn |> browser() |> get("/") |> html_response(200)
      assert html =~ "demo"
      assert html =~ "the demo repo"
      assert html =~ "first commit"
      assert html =~ "main"
      assert html =~ ~s(href="/demo")
    end

    test "says so when there are no repositories", %{conn: conn} do
      assert conn |> browser() |> get("/") |> html_response(200) =~ "No repositories."
    end

    test "answers JSON for API clients", %{conn: conn} do
      create_repo!("demo")

      assert %{"repos" => [repo]} =
               conn
               |> put_req_header("accept", "application/json")
               |> get("/")
               |> json_response(200)

      assert repo["name"] == "demo"
      assert repo["clone_url"] =~ "/demo.git"
    end
  end

  describe "POST /repos" do
    test "creates a repository and reports where it lives", %{conn: conn} do
      conn = post(conn, "/repos", %{"name" => "demo"})

      assert %{"name" => "demo", "url" => url} = json_response(conn, 201)
      assert url =~ "/demo.git"
      assert get_resp_header(conn, "location") == ["/demo"]
      assert {:ok, _} = Repos.fetch("demo")
    end

    test "a form submission redirects to the new repository", %{conn: conn} do
      conn = conn |> browser() |> post("/repos", %{"name" => "demo"})

      assert redirected_to(conn) == "/demo"
    end

    test "the second create of a name loses with 409", %{conn: conn} do
      create_repo!("demo")
      assert %{"error" => _} = conn |> post("/repos", %{"name" => "demo"}) |> json_response(409)
    end

    test "rejects invalid names", %{conn: conn} do
      assert conn |> post("/repos", %{"name" => "../evil"}) |> json_response(422)
      assert signed_in_conn() |> post("/repos", %{}) |> json_response(422)
    end
  end

  describe "GET /:repo" do
    test "shows the default branch, branches, tags, and recent commits", %{conn: conn} do
      repo =
        seed_repo!("demo", [
          %{message: "first commit", files: %{"a.txt" => "a\n"}},
          %{
            message: "second commit",
            change_id: "kmpsxwvrlouvzysnkulnnnttrrytwstn",
            files: %{"b.txt" => "b\n"}
          }
        ])

      git!(repo.dir, ["tag", "v1", "main"])

      html = conn |> get("/demo") |> html_response(200)
      assert html =~ "default"
      assert html =~ "main"
      assert html =~ "v1"
      assert html =~ "second commit"
      assert html =~ "first commit"
      assert html =~ "kmpsxwvr"
      assert html =~ "/demo.git"
      assert html =~ "ssh://git@"
    end

    test "resolves a name given with the .git suffix", %{conn: conn} do
      create_repo!("demo")
      assert conn |> get("/demo.git") |> html_response(200) =~ "demo"
    end

    test "reports an invalid repository directory instead of repairing it", %{
      conn: conn,
      root: root
    } do
      File.mkdir_p!(Path.join(root, "broken.git"))

      assert conn |> browser() |> get("/broken") |> html_response(500) =~
               "not a valid bare repository"

      assert File.ls!(Path.join(root, "broken.git")) == []
      assert Repos.list() == []
    end

    test "404s for a missing repository and 400s for an invalid name", %{conn: conn} do
      assert conn |> get("/missing") |> html_response(404) =~ "no such repository"

      assert signed_in_conn() |> get("/..%2Fevil") |> html_response(400) =~
               "invalid repository name"
    end
  end

  describe "POST /:repo/owner" do
    test "hands the repository to another user", %{conn: conn, user: admin} do
      create_repo!("demo", admin)
      other = user_fixture()

      conn = conn |> browser() |> post("/demo/owner", %{"email" => other.email})

      assert redirected_to(conn) == "/demo"
      assert {:ok, repo} = Repos.fetch("demo")
      assert repo.owner_uid == other.uid
    end

    test "is refused to someone who does not own it" do
      owner = user_fixture()
      create_repo!("demo", owner)
      conn = log_in_user(build_conn(), user_fixture()) |> browser()

      assert conn |> post("/demo/owner", %{"email" => "whoever@example.com"}) |> response(403) =~
               "only the owner or an admin"

      assert {:ok, repo} = Repos.fetch("demo")
      assert repo.owner_uid == owner.uid
    end

    test "reports an email nobody registered", %{conn: conn, user: admin} do
      create_repo!("demo", admin)

      assert conn
             |> browser()
             |> post("/demo/owner", %{"email" => "nobody@example.com"})
             |> response(404) =~ "no user with that email"
    end
  end

  describe "DELETE /:repo" do
    test "removes the repository from the listing", %{conn: conn} do
      create_repo!("demo")

      assert conn |> delete("/demo") |> response(204)
      assert Repos.list() == []
    end

    test "a form submission redirects to the listing", %{conn: conn} do
      create_repo!("demo")

      conn = conn |> browser() |> post("/demo", %{"_method" => "delete"})

      assert redirected_to(conn) == "/"
      assert Repos.list() == []
    end

    test "404s for a missing repository", %{conn: conn} do
      assert conn |> delete("/missing") |> json_response(404)
    end

    test "is refused to someone who does not own it" do
      create_repo!("demo", user_fixture())
      conn = log_in_user(build_conn(), user_fixture())

      assert conn |> delete("/demo") |> response(403)
      assert [_repo] = Repos.list()
    end
  end

  describe "ownership" do
    test "the creator owns what they created", %{conn: conn, user: user} do
      conn |> post("/repos", %{"name" => "demo"}) |> json_response(201)

      assert {:ok, repo} = Repos.fetch("demo")
      assert repo.owner_uid == user.uid
    end

    test "the page names the owner and offers the handover only to them", %{user: admin} do
      owner = user_fixture()
      create_repo!("demo", owner)

      html = log_in_user(build_conn(), owner) |> get("/demo") |> html_response(200)
      assert html =~ owner.email
      assert html =~ "hand to (email)"

      stranger = log_in_user(build_conn(), user_fixture())
      html = stranger |> get("/demo") |> html_response(200)
      assert html =~ owner.email
      refute html =~ "hand to (email)"

      assert log_in_user(build_conn(), admin) |> get("/demo") |> html_response(200) =~
               "hand to (email)"
    end
  end
end
