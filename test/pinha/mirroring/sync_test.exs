defmodule Pinha.Mirroring.SyncTest do
  @moduledoc """
  A sync against a real target: a bare repository reached over `file://`,
  with GitHub's API stubbed.
  """

  use Pinha.DataCase, async: false
  use Pinha.RepoCase, async: false

  import Pinha.ProvidersFixtures

  alias Pinha.Mirroring
  alias Pinha.Mirroring.Push
  alias Pinha.Mirroring.Sync
  alias Pinha.Providers.Secret
  alias Pinha.Repos
  alias Pinha.Repos.Snapshot

  @token "ghs_0123456789abcdefghijklmnopqrstuvwxyz"

  setup do
    user = user_fixture()
    account = github_account_fixture(user)
    repo = seed_repo!("demo", [%{message: "first", files: %{"a.txt" => "a\n"}}], user)
    target = github_target!()
    mirror = mirror_fixture(repo, user, account)

    stub_github(Map.new([token_route(@token), repository_route()]))

    %{user: user, account: account, repo: repo, target: target, mirror: mirror}
  end

  describe "run/2" do
    test "makes the target's branches and tags equal to the snapshot", %{
      repo: repo,
      target: target,
      mirror: mirror
    } do
      git!(repo.dir, ["tag", "v1", "main"])

      assert Sync.run(mirror.id, "test") == :synced
      assert target_refs(target) == source_refs(repo)
      assert %{"refs/heads/main" => _, "refs/tags/v1" => _} = target_refs(target)

      mirror = Mirroring.get(mirror.id)
      assert mirror.state == "active"
      assert mirror.last_failure == nil
      assert mirror.last_synced_at
      assert mirror.synced_snapshot_at
      refute Mirroring.Mirror.behind?(mirror)
    end

    test "force-updates and deletes so the target follows a rewrite", %{
      repo: repo,
      target: target,
      mirror: mirror
    } do
      git!(repo.dir, ["branch", "topic", "main"])
      assert Sync.run(mirror.id, "test") == :synced
      assert Map.has_key?(target_refs(target), "refs/heads/topic")

      work = tmp_dir!()
      git!(work, ["clone", "--quiet", repo.dir, "work"])
      clone = Path.join(work, "work")
      File.write!(Path.join(clone, "a.txt"), "rewritten\n")
      git!(clone, ["add", "-A"])
      git!(clone, ["commit", "--quiet", "--amend", "-m", "rewritten"])
      git!(clone, ["push", "--quiet", "--force", "origin", "HEAD:refs/heads/main"])
      git!(repo.dir, ["update-ref", "-d", "refs/heads/topic"])

      assert Sync.run(mirror.id, "test") == :synced
      assert target_refs(target) == source_refs(repo)
      refute Map.has_key?(target_refs(target), "refs/heads/topic")
    end

    test "records a terminal provider failure by disabling the mirror", %{mirror: mirror} do
      stub_github(%{
        {"POST", "/app/installations/99/access_tokens"} =>
          &error(&1, 404, "Not Found: installation")
      })

      assert {:failed, :terminal, _message} = Sync.run(mirror.id, "test")

      mirror = Mirroring.get(mirror.id)
      assert mirror.state == "disabled"
      assert mirror.disabled_reason == "installation_removed"
      assert mirror.last_failure =~ "Not Found"
    end

    test "leaves the mirror active after a transient failure", %{mirror: mirror} do
      stub_github(%{
        {"POST", "/app/installations/99/access_tokens"} => &error(&1, 500, "Server Error")
      })

      assert {:failed, :transient, _message} = Sync.run(mirror.id, "test")

      mirror = Mirroring.get(mirror.id)
      assert mirror.state == "active"
      assert mirror.last_failure =~ "Server Error"
    end

    test "keeps the installation token out of what it records", %{
      target: target,
      mirror: mirror
    } do
      File.rm_rf!(target.dir)

      assert {:failed, :terminal, message} = Sync.run(mirror.id, "test")
      refute message =~ @token

      mirror = Mirroring.get(mirror.id)
      assert mirror.last_failure
      refute mirror.last_failure =~ @token
      assert mirror.disabled_reason == "target_unreachable"
    end

    test "skips a mirror that is not active", %{mirror: mirror} do
      {:ok, mirror} = Mirroring.disable(mirror)
      assert Sync.run(mirror.id, "test") == :skipped
      assert Mirroring.get(mirror.id).last_failure == nil
    end
  end

  describe "leases" do
    setup %{repo: repo, target: target, mirror: mirror} do
      assert Sync.run(mirror.id, "test") == :synced
      %{push: push(target), main: source_refs(repo)["refs/heads/main"]}
    end

    test "refuses to overwrite a reference that changed after it was read", %{
      repo: repo,
      target: target,
      push: push,
      main: main
    } do
      # Someone pushed straight to the target after the sync read it.
      moved = stale_commit(target)
      git!(target.dir, ["update-ref", "refs/heads/main", moved])

      plan = %{
        updates: [%{ref: "refs/heads/main", old: main, new: main}],
        deletes: [],
        held: []
      }

      assert {:error, message} = Push.apply_plan(repo.dir, push, plan)
      assert message =~ "refs/heads/main"
      assert target_refs(target)["refs/heads/main"] == moved
    end

    test "lands creations before deletions, and keeps a refused deletion", %{
      repo: repo,
      target: target,
      push: push,
      main: main
    } do
      plan = %{
        updates: [%{ref: "refs/heads/renamed", old: nil, new: main}],
        deletes: [%{ref: "refs/heads/main", old: String.duplicate("0", 40)}],
        held: []
      }

      assert {:error, _message} = Push.apply_plan(repo.dir, push, plan)

      refs = target_refs(target)
      assert refs["refs/heads/renamed"] == main
      assert refs["refs/heads/main"] == main
    end

    test "refuses to create a reference the target has since gained", %{
      repo: repo,
      target: target,
      push: push,
      main: main
    } do
      # The plan was made when the target had no such reference.
      git!(target.dir, ["update-ref", "refs/heads/added", stale_commit(target)])
      added = target_refs(target)["refs/heads/added"]

      plan = %{updates: [%{ref: "refs/heads/added", old: nil, new: main}], deletes: [], held: []}

      assert {:error, message} = Push.apply_plan(repo.dir, push, plan)
      assert message =~ "refs/heads/added"
      assert target_refs(target)["refs/heads/added"] == added
    end
  end

  describe "plan/2" do
    test "holds a conflicted name at its target value and touches nothing else" do
      snapshot = %Snapshot{
        taken_at: DateTime.utc_now(),
        refs: %{"refs/heads/main" => "aaa", "refs/tags/v1" => "bbb"},
        conflicted: ["refs/heads/topic"]
      }

      remote = %{"refs/heads/main" => "old", "refs/heads/topic" => "theirs"}

      assert %{updates: updates, deletes: deletes, held: held} = Push.plan(snapshot, remote)

      assert updates == [
               %{ref: "refs/heads/main", old: "old", new: "aaa"},
               %{ref: "refs/tags/v1", old: nil, new: "bbb"}
             ]

      assert deletes == []
      assert held == ["refs/heads/topic"]
    end
  end

  defp push(target) do
    header = Secret.new("Authorization: Basic " <> Base.encode64("x-access-token:" <> @token))

    %{
      url: "file://" <> target.dir,
      auth_header: header,
      secrets: [Secret.new(@token), header],
      target_name: "octo/demo",
      target_url: "https://github.test/octo/demo"
    }
  end

  defp source_refs(repo) do
    {:ok, snapshot} = Repos.snapshot(repo)
    snapshot.refs
  end

  defp target_refs(target) do
    target.dir
    |> refs_of()
    |> Map.new()
  end

  defp refs_of(dir) do
    git!(dir, ["for-each-ref", "--format=%(objectname) %(refname)", "refs/heads/", "refs/tags/"])
    |> String.split("\n", trim: true)
    |> Enum.map(fn line ->
      [oid, ref] = String.split(line, " ", parts: 2)
      {ref, oid}
    end)
  end

  defp stale_commit(target) do
    target.dir
    |> git!(["commit-tree", "-m", "moved on", empty_tree(target)])
    |> String.trim()
  end

  defp empty_tree(target) do
    target.dir |> git!(["hash-object", "-t", "tree", "/dev/null", "-w"]) |> String.trim()
  end

  defp error(conn, status, message) do
    conn |> Plug.Conn.put_status(status) |> Req.Test.json(%{"message" => message})
  end
end
