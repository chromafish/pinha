defmodule PinhaWeb.GitHttpControllerTest do
  use PinhaWeb.ConnCase, async: false

  alias Pinha.Git

  @change_id "kmpsxwvrlouvzysnkulnnnttrrytwstn"

  setup %{user: user} do
    [url: authenticated_url(user, "/r/demo.git")]
  end

  test "clone, push, and clone back over HTTPS transport", %{url: url} do
    create_repo!("demo")
    work = tmp_dir!()
    clone = Path.join(work, "one")

    assert git!(work, ["clone", "--quiet", url, clone]) =~ ~r/empty repository|^$/

    File.write!(Path.join(clone, "README.md"), "hello\n")
    git!(clone, ["add", "-A"])
    git!(clone, ["commit", "--quiet", "-m", "first commit\n\nchange-id: #{@change_id}"])
    git!(clone, ["push", "--quiet", "origin", "main"])

    second = Path.join(work, "two")
    git!(work, ["clone", "--quiet", url, second])

    assert File.read!(Path.join(second, "README.md")) == "hello\n"
    assert git!(second, ["log", "--format=%s"]) == "first commit\n"
  end

  test "the change-id trailer survives a push and a fetch untouched", %{url: url} do
    create_repo!("demo")
    work = tmp_dir!()
    clone = Path.join(work, "one")
    git!(work, ["clone", "--quiet", url, clone])
    File.write!(Path.join(clone, "a.txt"), "a\n")
    git!(clone, ["add", "-A"])
    git!(clone, ["commit", "--quiet", "-m", "with trailer\n\nchange-id: #{@change_id}"])
    git!(clone, ["push", "--quiet", "origin", "main"])

    {:ok, repo} = Repos.fetch("demo")
    [commit] = Git.log(repo, "main", limit: 1)
    assert commit.change_id == @change_id

    second = Path.join(work, "two")
    git!(work, ["clone", "--quiet", url, second])
    assert git!(second, ["log", "--format=%B", "-1"]) =~ "change-id: #{@change_id}"
  end

  test "fetch picks up refs pushed after the clone", %{url: url} do
    repo = seed_repo!("demo", [%{message: "first", files: %{"a.txt" => "a\n"}}])
    work = tmp_dir!()
    clone = Path.join(work, "one")
    git!(work, ["clone", "--quiet", url, clone])

    other = tmp_dir!()
    git!(File.cwd!(), ["clone", "--quiet", repo.dir, other])
    File.write!(Path.join(other, "b.txt"), "b\n")
    git!(other, ["add", "-A"])
    git!(other, ["commit", "--quiet", "-m", "second"])
    git!(other, ["push", "--quiet", "origin", "main"])

    git!(clone, ["fetch", "--quiet", "origin"])
    assert git!(clone, ["log", "--format=%s", "origin/main"]) == "second\nfirst\n"
  end

  test "protocol v2 clone works", %{url: url} do
    seed_repo!("demo", [%{message: "first", files: %{"a.txt" => "a\n"}}])
    work = tmp_dir!()
    git!(work, ["-c", "protocol.version=2", "clone", "--quiet", url, Path.join(work, "v2")])

    assert git!(Path.join(work, "v2"), ["log", "--format=%s"]) == "first\n"
  end

  test "push creates, updates, force-updates, and deletes refs", %{url: url} do
    repo = seed_repo!("demo", [%{message: "first", files: %{"a.txt" => "a\n"}}])
    work = tmp_dir!()
    clone = Path.join(work, "one")
    git!(work, ["clone", "--quiet", url, clone])

    git!(clone, ["checkout", "--quiet", "-b", "topic"])
    File.write!(Path.join(clone, "b.txt"), "b\n")
    git!(clone, ["add", "-A"])
    git!(clone, ["commit", "--quiet", "-m", "topic commit"])
    git!(clone, ["push", "--quiet", "origin", "topic"])
    assert "topic" in Enum.map(Git.branches(repo), & &1.name)

    git!(clone, ["tag", "v1"])
    git!(clone, ["push", "--quiet", "origin", "v1"])
    assert Enum.map(Git.tags(repo), & &1.name) == ["v1"]

    git!(clone, ["commit", "--quiet", "--amend", "-m", "rewritten"])
    git!(clone, ["push", "--quiet", "--force", "origin", "topic"])
    assert [%{subject: "rewritten"}] = Git.log(repo, "topic", limit: 1)

    git!(clone, ["push", "--quiet", "origin", ":topic"])
    refute "topic" in Enum.map(Git.branches(repo), & &1.name)
  end

  test "info/refs advertises the service and refuses the dumb protocol", %{conn: conn} do
    seed_repo!("demo", [%{message: "first", files: %{"a.txt" => "a\n"}}])

    conn = get(conn, "/r/demo.git/info/refs?service=git-upload-pack")
    assert response_content_type(conn, :"x-git-upload-pack-advertisement")
    body = response(conn, 200)
    assert String.starts_with?(body, "001e# service=git-upload-pack\n0000")
    assert body =~ "refs/heads/main"
    assert get_resp_header(conn, "cache-control") == ["no-cache, max-age=0, must-revalidate"]

    assert response(get(signed_in_conn(), "/r/demo.git/info/refs"), 403) =~ "smart HTTP"
    assert response(get(signed_in_conn(), "/r/demo.git/info/refs?service=git-evil"), 403)
  end

  test "unknown and invalid repositories are rejected", %{conn: conn} do
    assert response(get(conn, "/r/missing.git/info/refs?service=git-upload-pack"), 404)
    assert response(get(signed_in_conn(), "/r/..%2Fevil/info/refs?service=git-upload-pack"), 400)

    conn =
      signed_in_conn()
      |> put_req_header("content-type", "application/x-git-upload-pack-request")
      |> post("/r/missing.git/git-upload-pack", "0000")

    assert response(conn, 404)
  end

  test "a gzipped RPC body is inflated before git reads it" do
    seed_repo!("demo", [%{message: "first", files: %{"a.txt" => "a\n"}}])

    conn =
      signed_in_conn()
      |> put_req_header("content-type", "application/x-git-upload-pack-request")
      |> put_req_header("content-encoding", "gzip")
      |> post("/r/demo.git/git-upload-pack", :zlib.gzip("0000"))

    assert response(conn, 200) == ""
    assert response_content_type(conn, :"x-git-upload-pack-result")
  end

  describe "push access" do
    test "an ordinary user reads a repository they do not own, and cannot push", %{user: admin} do
      seed_repo!("demo", [%{message: "first", files: %{"a.txt" => "a\n"}}])
      {:ok, _} = Repos.set_owner("demo", admin.username)

      ordinary = user_fixture()
      url = authenticated_url(ordinary, "/r/demo.git")
      work = tmp_dir!()
      clone = Path.join(work, "one")

      git!(work, ["clone", "--quiet", url, clone])

      File.write!(Path.join(clone, "b.txt"), "b\n")
      git!(clone, ["add", "-A"])
      git!(clone, ["commit", "--quiet", "-m", "second"])

      {output, status} =
        System.cmd("git", ["push", "origin", "main"], cd: clone, stderr_to_stdout: true)

      assert status != 0
      assert output =~ "you do not have push access to demo"
    end

    test "the owner pushes", %{user: admin} do
      create_repo!("demo", admin)
      url = authenticated_url(admin, "/r/demo.git")
      work = tmp_dir!()
      clone = Path.join(work, "one")

      git!(work, ["clone", "--quiet", url, clone])
      File.write!(Path.join(clone, "a.txt"), "a\n")
      git!(clone, ["add", "-A"])
      git!(clone, ["commit", "--quiet", "-m", "first"])

      assert git!(clone, ["push", "--quiet", "origin", "main"])
    end
  end
end
