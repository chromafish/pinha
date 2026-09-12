defmodule Pinha.GitTest do
  use Pinha.RepoCase, async: false

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

  test "default_branch/1 reads HEAD", %{repo: repo} do
    assert Git.default_branch(repo) == "main"
  end

  test "branches/1 and tags/1 report refs with their tips", %{repo: repo, commits: [head | _]} do
    assert [%{name: "main", id: id, subject: "second commit"}] = Git.branches(repo)
    assert id == head.id
    assert Git.tags(repo) == []

    git!(repo.dir, ["tag", "v1", head.id])
    assert [%{name: "v1", id: ^id}] = Git.tags(repo)
  end

  test "log/3 reads change-id trailers", %{commits: [second, first]} do
    assert second.subject == "second commit"
    assert second.change_id == @second_change
    assert first.change_id == @first_change
    assert first.parents == []
    assert second.parents == [first.id]
    assert second.author_name == "Tester"
  end

  test "log/3 limits and filters by path", %{repo: repo} do
    assert length(Git.log(repo, "main", limit: 1)) == 1
    assert [%{subject: "first commit"}] = Git.log(repo, "main", limit: 10, path: "src/a.ex")
  end

  describe "resolve/2" do
    test "full commit ids", %{repo: repo, commits: [head | _]} do
      assert {:ok, %{id: id, kind: :commit, change_id: @second_change}} =
               Git.resolve(repo, head.id)

      assert id == head.id
    end

    test "does not resolve short commit ids", %{repo: repo, commits: [head | _]} do
      short = binary_part(head.id, 0, 8)
      assert Git.resolve(repo, short) == {:error, :not_found}
    end

    test "branches and tags", %{repo: repo, commits: [head | _]} do
      assert {:ok, %{kind: :branch, id: id}} = Git.resolve(repo, "main")
      assert id == head.id

      git!(repo.dir, ["tag", "v1", head.id])
      assert {:ok, %{kind: :tag, id: ^id}} = Git.resolve(repo, "v1")
    end

    test "annotated tags peel to their commit", %{repo: repo, commits: [head | _]} do
      git!(repo.dir, ["tag", "-a", "v2", "-m", "release", head.id])
      assert {:ok, %{kind: :tag, id: id}} = Git.resolve(repo, "v2")
      assert id == head.id
    end

    test "full change ids", %{repo: repo, commits: [_second, first]} do
      assert {:ok, %{kind: :change_id, id: id, change_id: @first_change}} =
               Git.resolve(repo, @first_change)

      assert id == first.id
    end

    test "unique change-id prefixes", %{repo: repo, commits: [_second, first]} do
      assert {:ok, %{kind: :change_id, id: id}} =
               Git.resolve(repo, binary_part(@first_change, 0, 5))

      assert id == first.id
    end

    test "change ids are matched case-insensitively", %{repo: repo, commits: [_second, first]} do
      assert {:ok, %{id: id}} = Git.resolve(repo, String.upcase(@first_change))
      assert id == first.id
    end

    test "ambiguous prefixes list every match", %{repo: repo} do
      sibling = String.replace_suffix(@first_change, "wstn", "zzzz")
      work = tmp_dir!()
      git!(File.cwd!(), ["clone", "--quiet", repo.dir, work])
      File.write!(Path.join(work, "README.md"), "sibling\n")
      git!(work, ["commit", "--quiet", "-am", "sibling commit\n\nchange-id: #{sibling}"])
      git!(work, ["push", "--quiet", "origin", "HEAD:refs/heads/sibling"])

      assert {:ambiguous, matches} = Git.resolve(repo, binary_part(@first_change, 0, 6))
      assert length(matches) == 2
      assert Enum.sort(Enum.map(matches, & &1.change_id)) == Enum.sort([@first_change, sibling])

      assert {:ok, %{kind: :change_id}} = Git.resolve(repo, @first_change)
    end

    test "divergent commits sharing a change id are listed individually", %{repo: repo} do
      work = tmp_dir!()
      git!(File.cwd!(), ["clone", "--quiet", repo.dir, work])
      File.write!(Path.join(work, "README.md"), "diverged\n")
      git!(work, ["commit", "--quiet", "-am", "divergent\n\nchange-id: #{@second_change}"])
      git!(work, ["push", "--quiet", "origin", "HEAD:refs/heads/other"])

      assert {:ambiguous, matches} = Git.resolve(repo, @second_change)
      assert length(matches) == 2
      assert Enum.all?(matches, &(&1.change_id == @second_change))
    end

    test "unknown revisions", %{repo: repo} do
      assert Git.resolve(repo, "nope") == {:error, :not_found}
      assert Git.resolve(repo, "not a rev") == {:error, :not_found}
    end
  end

  describe "trees and blobs" do
    test "list_tree/3 sorts directories first", %{repo: repo, commits: [head | _]} do
      assert {:ok, entries} = Git.list_tree(repo, head.id, "")
      assert Enum.map(entries, & &1.name) == ["bin", "src", "README.md"]
      assert [%{type: "tree"}, %{type: "tree"}, %{type: "blob", size: 12}] = entries
    end

    test "list_tree/3 descends into subdirectories", %{repo: repo, commits: [head | _]} do
      assert {:ok, [%{name: "a.ex", path: "src/a.ex"}]} = Git.list_tree(repo, head.id, "src")
    end

    test "object_type/3 tells trees, blobs, and missing paths apart", %{
      repo: repo,
      commits: [head | _]
    } do
      assert Git.object_type(repo, head.id, "") == {:ok, "tree"}
      assert Git.object_type(repo, head.id, "src") == {:ok, "tree"}
      assert Git.object_type(repo, head.id, "README.md") == {:ok, "blob"}
      assert Git.object_type(repo, head.id, "nope") == :error
    end

    test "blob/3 returns bytes and flags binary content", %{repo: repo, commits: [head | _]} do
      assert {:ok, %{content: "hello\nworld\n", size: 12, binary?: false}} =
               Git.blob(repo, head.id, "README.md")

      assert {:ok, %{content: <<0, 1, 2, 3>>, binary?: true}} =
               Git.blob(repo, head.id, "bin/blob")

      assert Git.blob(repo, head.id, "nope") == {:error, :not_found}
    end
  end

  describe "commits" do
    test "commit/2 returns metadata with the change-id trailer", %{
      repo: repo,
      commits: [head | _]
    } do
      assert {:ok, commit} = Git.commit(repo, head.id)
      assert commit.id == head.id
      assert commit.subject == "second commit"
      assert commit.change_id == @second_change
      assert commit.body =~ "change-id: #{@second_change}"
    end

    test "commit/2 reports unknown ids", %{repo: repo} do
      assert Git.commit(repo, String.duplicate("0", 40)) == {:error, :not_found}
    end

    test "diff/2 and diff_stat/2 describe the change", %{repo: repo, commits: [head, root]} do
      diff = Git.diff(repo, head.id)
      assert diff =~ "--- a/README.md"
      assert diff =~ "+world"

      assert [%{path: "README.md", added: "1", removed: "0"}, %{path: "bin/blob"}] =
               Enum.sort_by(Git.diff_stat(repo, head.id), & &1.path)

      assert Git.diff(repo, root.id) =~ "+hello"
    end
  end

  test "scrub/1 replaces invalid UTF-8" do
    assert Git.scrub("ok") == "ok"
    assert String.valid?(Git.scrub(<<0xFF, "text">>))
  end

  describe "a git invocation that fails" do
    setup do
      previous = Application.get_env(:pinha, :widelog)
      Application.put_env(:pinha, :widelog, true)
      on_exit(fn -> Application.put_env(:pinha, :widelog, previous) end)
      :ok
    end

    test "says so on one log line, carrying what git wrote to stderr", %{repo: repo} do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert {:error, {:exit, code}} = Git.run(repo.dir, ["rev-parse", "--verify", "nope"])
          assert code != 0
        end)

      assert {:ok, line} = Jason.decode(output)
      assert line["event"] == "git"
      assert line["repo"] == "demo"
      assert line["status"] != 0
      assert line["stderr"] =~ "fatal:"
      assert "rev-parse" in line["argv"]
    end

    test "bytes from a URL that are not UTF-8 do not break the line", %{repo: repo} do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert {:error, {:exit, _}} =
                   Git.run(repo.dir, ["cat-file", "-t", "HEAD:" <> <<0xFF>>])
        end)

      assert {:ok, line} = Jason.decode(output)
      assert line["event"] == "git"
      assert "cat-file" in line["argv"]
    end

    test "a command that works logs nothing", %{repo: repo} do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert {:ok, _} = Git.run(repo.dir, ["rev-parse", "HEAD"])
        end)

      assert output == ""
    end
  end
end
