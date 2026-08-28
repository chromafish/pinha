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
      assert build_conn() |> post("/repos", %{}) |> json_response(422)
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
      assert html =~ "git clone"
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
      assert build_conn() |> get("/..%2Fevil") |> html_response(400) =~ "invalid repository name"
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
  end
end
