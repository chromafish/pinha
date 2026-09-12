defmodule PinhaWeb.BrowseControllerTest do
  use PinhaWeb.ConnCase, async: false

  alias Pinha.Git

  @first_change "kmpsxwvrlouvzysnkulnnnttrrytwstn"
  @second_change "znlwuprqroqnpymvvusotzrukvtrwsxs"

  setup do
    repo =
      seed_repo!("demo", [
        %{
          message: "first commit",
          change_id: @first_change,
          files: %{"README.md" => "hello\n", "src/a.ex" => "defmodule A do\nend\n"}
        },
        %{
          message: "second commit",
          change_id: @second_change,
          files: %{"README.md" => "hello\nworld\n", "bin/blob" => <<0, 1, 2, 3>>}
        }
      ])

    [repo: repo, commits: Git.log(repo, "main", limit: 10)]
  end

  describe "tree" do
    test "lists the root of the default branch", %{conn: conn} do
      html = conn |> get("/r/demo/tree") |> html_response(200)
      assert html =~ "README.md"
      assert html =~ "src/"
      assert html =~ "branch"
    end

    test "lists a subdirectory and links back to its parent", %{conn: conn} do
      html = conn |> get("/r/demo/tree/main/src") |> html_response(200)
      assert html =~ "a.ex"
      assert html =~ "/r/demo/tree/main\""
    end

    test "renders a blob with line numbers", %{conn: conn} do
      html = conn |> get("/r/demo/tree/main/README.md") |> html_response(200)
      assert html =~ "hello"
      assert html =~ "world"
      assert html =~ "Raw"
    end

    test "does not try to render binary files", %{conn: conn} do
      assert conn |> get("/r/demo/tree/main/bin/blob") |> html_response(200) =~ "Binary file"
    end

    test "browses at a full commit id and at a change id", %{
      conn: conn,
      commits: [_second, first]
    } do
      assert conn |> get("/r/demo/tree/#{first.id}/README.md") |> html_response(200) =~ "hello"

      assert conn |> get("/r/demo/tree/#{@first_change}/README.md") |> html_response(200) =~
               "hello"

      prefix = binary_part(@first_change, 0, 6)
      assert conn |> get("/r/demo/tree/#{prefix}") |> html_response(200) =~ "README.md"
    end

    test "an ambiguous change id lists every match", %{conn: conn, repo: repo} do
      work = tmp_dir!()
      git!(File.cwd!(), ["clone", "--quiet", repo.dir, work])
      File.write!(Path.join(work, "README.md"), "diverged\n")
      git!(work, ["commit", "--quiet", "-am", "divergent\n\nchange-id: #{@second_change}"])
      git!(work, ["push", "--quiet", "origin", "HEAD:refs/heads/other"])

      html = conn |> get("/r/demo/tree/#{@second_change}") |> html_response(300)
      assert html =~ "Ambiguous change id"
      assert html =~ "matches 2 commits"
      assert html =~ "divergent"
    end

    test "404s for unknown revisions and paths", %{conn: conn} do
      assert conn |> get("/r/demo/tree/nope") |> html_response(404) =~ "no such revision"
      assert conn |> get("/r/demo/tree/main/nope") |> html_response(404) =~ "no such path"
    end

    test "short commit ids do not resolve", %{conn: conn, commits: [head | _]} do
      short = binary_part(head.id, 0, 8)
      assert conn |> get("/r/demo/tree/#{short}") |> html_response(404)
    end

    test "rejects paths that try to escape the tree", %{conn: conn} do
      assert conn |> get("/r/demo/tree/main/..%2Fetc") |> html_response(400) =~ "invalid path"
    end
  end

  describe "raw" do
    test "serves the exact bytes with a non-sniffable content type", %{conn: conn} do
      conn = get(conn, "/r/demo/raw/main/README.md")

      assert response(conn, 200) == "hello\nworld\n"
      assert get_resp_header(conn, "content-type") == ["application/octet-stream"]
      assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
      assert get_resp_header(conn, "content-disposition") == [~s(inline; filename="README.md")]
    end

    test "serves binary blobs unchanged", %{conn: conn} do
      assert response(get(conn, "/r/demo/raw/main/bin/blob"), 200) == <<0, 1, 2, 3>>
    end

    test "404s for directories and missing files", %{conn: conn} do
      assert conn |> get("/r/demo/raw/main/src") |> html_response(404)
      assert conn |> get("/r/demo/raw/main/nope") |> html_response(404)
    end
  end

  describe "commit" do
    test "shows metadata, parents, the change id, and the full diff", %{
      conn: conn,
      commits: [head, root]
    } do
      html = conn |> get("/r/demo/commit/#{head.id}") |> html_response(200)

      assert html =~ head.id
      assert html =~ @second_change
      assert html =~ "second commit"
      assert html =~ "Tester"
      assert html =~ root.id |> binary_part(0, 12)
      assert html =~ "+world"
      assert html =~ "README.md"
    end

    test "shows a root commit as parentless", %{conn: conn, commits: [_head, root]} do
      html = conn |> get("/r/demo/commit/#{root.id}") |> html_response(200)
      assert html =~ "none, root commit"
      assert html =~ "+hello"
    end

    test "accepts a change id in place of a commit id", %{conn: conn, commits: [_head, root]} do
      assert conn |> get("/r/demo/commit/#{@first_change}") |> html_response(200) =~ root.id
    end

    test "404s for unknown commits", %{conn: conn} do
      assert conn |> get("/r/demo/commit/#{String.duplicate("0", 40)}") |> html_response(404)
    end
  end

  test "browsing an unknown repository 404s", %{conn: conn} do
    assert conn |> get("/r/missing/tree/main") |> html_response(404) =~ "no such repository"
  end

  describe "a path that is not UTF-8" do
    setup do
      # The widelog is off in the suite, and writing the line is where this
      # used to fail.
      previous = Application.get_env(:pinha, :widelog)
      Application.put_env(:pinha, :widelog, true)
      on_exit(fn -> Application.put_env(:pinha, :widelog, previous) end)
      :ok
    end

    test "is a 404 rather than a crash", %{conn: conn} do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert conn |> get("/r/demo/tree/main/%FF") |> response(404)
        end)

      # git was asked for the path and failed, and the line encoded anyway.
      assert output =~ ~s("event":"git")

      assert Enum.all?(
               String.split(output, "\n", trim: true),
               &match?({:ok, _}, Jason.decode(&1))
             )
    end
  end
end
