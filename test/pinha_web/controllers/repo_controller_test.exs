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
      assert html =~ "Latest commit"
      assert html =~ ~s(href="/r/demo")
      assert html =~ ~s(data-repository-kind="git")
      refute html =~ "reference-kind"
      refute html =~ ">Commit</th>"
      refute html =~ ">Type<"
      refute html =~ "Plain Git repository and history"
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
      assert repo["clone_url"] =~ "/r/demo.git"
      assert repo["repository_model"] == "git"
      assert repo["history_model"] == "git"
    end

    test "lists Jujutsu history without a repository type column", %{conn: conn} do
      seed_repo!("jj-demo", [
        %{
          message: "a jj change",
          change_id: "kmpsxwvrlouvzysnkulnnnttrrytwstn",
          files: %{"a.txt" => "a\n"}
        }
      ])

      html = conn |> browser() |> get("/") |> html_response(200)
      assert html =~ ~s(data-repository-kind="jujutsu")
      assert html =~ "bookmark-ref"
      refute html =~ "reference-kind"
      refute html =~ "Jujutsu via Git"

      assert %{"repos" => [%{"repository_model" => "git", "history_model" => "jujutsu"}]} =
               conn
               |> put_req_header("accept", "application/json")
               |> get("/")
               |> json_response(200)
    end
  end

  describe "POST /repos" do
    test "creates a repository and reports where it lives", %{conn: conn} do
      conn = post(conn, "/repos", %{"name" => "demo"})

      assert %{"name" => "demo", "url" => url} = json_response(conn, 201)
      assert url =~ "/r/demo.git"
      assert json_response(conn, 201)["repository_model"] == "git"
      assert get_resp_header(conn, "location") == ["/r/demo"]
      assert {:ok, _} = Repos.fetch("demo")
    end

    test "a form submission redirects to the new repository", %{conn: conn} do
      conn = conn |> browser() |> post("/repos", %{"name" => "demo"})

      assert redirected_to(conn) == "/r/demo"
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
    test "shows the default bookmark, bookmarks, tags, and recent changes", %{conn: conn} do
      repo =
        seed_repo!("demo", [
          %{
            message: "first commit",
            author_date: "2026-02-02T03:04:05+00:00",
            files: %{"a.txt" => "a\n"}
          },
          %{
            message: "second commit",
            author_date: "2026-01-02T03:04:05+00:00",
            change_id: "kmpsxwvrlouvzysnkulnnnttrrytwstn",
            files: %{"b.txt" => "b\n"}
          }
        ])

      git!(repo.dir, ["tag", "v1", "main"])

      html = conn |> get("/r/demo") |> html_response(200)
      assert html =~ ~s(data-repository-kind="jujutsu")
      assert html =~ "Jujutsu via Git"
      assert html =~ "Bookmarks &amp; tags"
      assert html =~ "Recent changes"
      assert html =~ "bookmark-ref"
      assert html =~ "git HEAD"
      assert html =~ "main"
      assert html =~ "v1"
      assert html =~ "second commit"
      assert html =~ "first commit"
      assert html =~ "kmpsxwvr"
      assert html =~ "/r/demo.git"
      assert html =~ "ssh://git@"
      assert html =~ "<th>Message</th>"
      refute html =~ "<th>Subject</th>"

      {first_index, _length} = :binary.match(html, "first commit")
      {second_index, _length} = :binary.match(html, "second commit")
      assert first_index < second_index
    end

    test "shows history when tags, but no bookmarks, make commits reachable", %{conn: conn} do
      repo = seed_repo!("demo", [%{message: "tagged change", files: %{"a.txt" => "a\n"}}])
      git!(repo.dir, ["tag", "snapshot", "main"])
      git!(repo.dir, ["update-ref", "-d", "refs/heads/main"])

      listing = conn |> browser() |> get("/") |> html_response(200)
      assert listing =~ "tagged change"
      refute listing =~ "no changes"

      html =
        signed_in_conn()
        |> get("/r/demo")
        |> html_response(200)

      assert html =~ "No branches"
      assert html =~ "snapshot"
      assert html =~ "tagged change"
      refute html =~ "No commits have been pushed"
    end

    test "lays out refs above the README and recent history", %{conn: conn} do
      seed_repo!("demo", [
        %{
          message: "document the project",
          files: %{"README.md" => "# Demo\n\nA useful project.\n"}
        }
      ])

      html = conn |> get("/r/demo") |> html_response(200)

      assert html =~ ~s(id="repository-refs")
      assert html =~ ~s(class="ref-lanes")
      assert html =~ ~s(id="repository-readme")
      assert html =~ ~s(id="repository-history")
      assert html =~ "Demo</h1>"

      {refs_index, _length} = :binary.match(html, ~s(id="repository-refs"))
      {readme_index, _length} = :binary.match(html, ~s(id="repository-readme"))
      {history_index, _length} = :binary.match(html, ~s(id="repository-history"))

      assert refs_index < readme_index
      assert readme_index < history_index
    end

    test "keeps Git terminology and emphasis for a plain repository", %{conn: conn} do
      seed_repo!("plain", [%{message: "plain commit", files: %{"a.txt" => "a\n"}}])

      html = conn |> get("/r/plain") |> html_response(200)

      assert html =~ ~s(data-repository-kind="git")
      assert html =~ "Plain Git repository and history"
      assert html =~ "Branches &amp; tags"
      assert html =~ "Recent commits"
      assert html =~ ">Branch<"
      assert html =~ "default"
      refute html =~ "bookmark-ref"
    end

    test "uses the persisted Jujutsu model even before it has changes", %{conn: conn} do
      repo = create_repo!("native")
      git!(repo.dir, ["config", "pinha.kind", "jj"])

      html = conn |> get("/r/native") |> html_response(200)

      assert html =~ ~s(data-repository-kind="jujutsu")
      assert html =~ ~s(data-repository-model="jj")
      assert html =~ "Native Jujutsu repository with Git-compatible transport"
      assert html =~ "No bookmarks"
      assert html =~ "No changes have been published"
    end

    test "resolves a name given with the .git suffix", %{conn: conn} do
      create_repo!("demo")
      assert conn |> get("/r/demo.git") |> html_response(200) =~ "demo"
    end

    test "reports an invalid repository directory instead of repairing it", %{
      conn: conn,
      root: root
    } do
      File.mkdir_p!(Path.join(root, "broken.git"))

      assert conn |> browser() |> get("/r/broken") |> html_response(500) =~
               "not a valid bare repository"

      assert File.ls!(Path.join(root, "broken.git")) == []
      assert Repos.list() == []
    end

    test "404s for a missing repository and 400s for an invalid name", %{conn: conn} do
      assert conn |> get("/r/missing") |> html_response(404) =~ "no such repository"

      assert signed_in_conn() |> get("/r/..%2Fevil") |> html_response(400) =~
               "invalid repository name"
    end
  end

  describe "POST /:repo/owner" do
    test "hands the repository to another user", %{conn: conn, user: admin} do
      create_repo!("demo", admin)
      other = user_fixture()

      conn = conn |> browser() |> post("/r/demo/owner", %{"username" => other.username})

      assert redirected_to(conn) == "/r/demo"
      assert {:ok, repo} = Repos.fetch("demo")
      assert repo.owner_uid == other.uid
    end

    test "is refused to someone who does not own it" do
      owner = user_fixture()
      create_repo!("demo", owner)
      conn = log_in_user(build_conn(), user_fixture()) |> browser()

      assert conn |> post("/r/demo/owner", %{"username" => "whoever"}) |> response(403) =~
               "only the owner or an admin"

      assert {:ok, repo} = Repos.fetch("demo")
      assert repo.owner_uid == owner.uid
    end

    test "reports an email nobody registered", %{conn: conn, user: admin} do
      create_repo!("demo", admin)

      assert conn
             |> browser()
             |> post("/r/demo/owner", %{"username" => "nobody"})
             |> response(404) =~ "no user with that username"
    end
  end

  describe "DELETE /:repo" do
    test "removes the repository from the listing", %{conn: conn} do
      create_repo!("demo")

      assert conn |> delete("/r/demo") |> response(204)
      assert Repos.list() == []
    end

    test "a form submission redirects to the listing", %{conn: conn} do
      create_repo!("demo")

      conn = conn |> browser() |> post("/r/demo", %{"_method" => "delete"})

      assert redirected_to(conn) == "/"
      assert Repos.list() == []
    end

    test "404s for a missing repository", %{conn: conn} do
      assert conn |> delete("/r/missing") |> json_response(404)
    end

    test "is refused to someone who does not own it" do
      create_repo!("demo", user_fixture())
      conn = log_in_user(build_conn(), user_fixture())

      assert conn |> delete("/r/demo") |> response(403)
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

      html = log_in_user(build_conn(), owner) |> get("/r/demo") |> html_response(200)
      assert html =~ owner.username
      refute html =~ owner.email
      assert html =~ "hand to (username)"

      stranger = log_in_user(build_conn(), user_fixture())
      html = stranger |> get("/r/demo") |> html_response(200)
      assert html =~ owner.username
      refute html =~ "hand to (username)"

      assert log_in_user(build_conn(), admin) |> get("/r/demo") |> html_response(200) =~
               "hand to (username)"
    end
  end
end
