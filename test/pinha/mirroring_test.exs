defmodule Pinha.MirroringTest do
  @moduledoc "Triggers, the connection check, outcomes, and provider events."

  use Pinha.DataCase, async: false
  use Pinha.RepoCase, async: false
  use Oban.Testing, repo: Pinha.Repo

  import Pinha.ProvidersFixtures

  alias Pinha.Mirroring
  alias Pinha.Mirroring.Mirror
  alias Pinha.Mirroring.SyncWorker
  alias Pinha.Providers
  alias Pinha.Providers.Error
  alias Pinha.Repos

  setup do
    user = user_fixture()
    account = github_account_fixture(user)
    repo = seed_repo!("demo", [%{message: "first", files: %{"a.txt" => "a\n"}}], user)

    %{user: user, account: account, repo: repo, mirror: mirror_fixture(repo, user, account)}
  end

  describe "written/1" do
    test "records the write, starts one sync, and collapses a burst", %{
      repo: repo,
      mirror: mirror
    } do
      :ok = Mirroring.written(repo)
      :ok = Mirroring.written(repo)
      :ok = Mirroring.written(repo)

      assert [job] = all_enqueued(worker: SyncWorker)
      assert job.args["mirror_id"] == mirror.id
      assert job.args["trigger"] == "write"

      mirror = Mirroring.get(mirror.id)
      assert mirror.last_written_at
      assert Mirror.behind?(mirror)
    end

    test "a disabled mirror records the write and starts nothing", %{
      repo: repo,
      mirror: mirror
    } do
      {:ok, _mirror} = Mirroring.disable(mirror)
      :ok = Mirroring.written(repo)

      assert all_enqueued(worker: SyncWorker) == []
      assert Mirroring.get(mirror.id).last_written_at
    end

    test "a repository with no mirror writes nothing", %{user: user} do
      other = seed_repo!("other", [%{message: "first", files: %{"a.txt" => "a\n"}}], user)

      assert Mirroring.written(other) == :ok
      assert all_enqueued(worker: SyncWorker) == []
    end
  end

  describe "the connection check" do
    test "passes for the owner who connected it", %{mirror: mirror} do
      assert {:ok, repo, account, capability} = Mirroring.check_connection(mirror)
      assert repo.name == "demo"
      assert account.provider == "github"
      assert capability == Pinha.Providers.GitHub.Mirroring
    end

    test "a repository gone from under its name is terminal", %{mirror: mirror} do
      :ok = Repos.delete("demo")
      mirror = Mirroring.get(mirror.id) || mirror

      assert {:error, %Error{kind: :terminal, reason: :repository_gone}} =
               Mirroring.check_connection(mirror)
    end

    test "a change of owner is terminal", %{repo: repo, mirror: mirror} do
      other = user_fixture()
      {:ok, _repo} = Repos.set_owner(repo.name, other.username)

      assert {:error, %Error{kind: :terminal, reason: :owner_changed}} =
               Mirroring.check_connection(mirror)
    end

    test "an unlinked account is terminal", %{user: user, mirror: mirror} do
      {:ok, _account} = Providers.Accounts.unlink(user, "github")

      assert {:error, %Error{kind: :terminal, reason: :account_unlinked}} =
               Mirroring.check_connection(Mirroring.get(mirror.id))
    end
  end

  describe "outcomes" do
    test "a failure of an older snapshot is not recorded over a newer success", %{
      mirror: mirror
    } do
      newer = DateTime.utc_now()
      older = DateTime.add(newer, -60, :second)

      :ok =
        Mirroring.record_success(
          mirror,
          %Pinha.Repos.Snapshot{taken_at: newer, refs: %{}},
          [],
          %{target_name: mirror.target_name, target_url: mirror.target_url}
        )

      :ok = Mirroring.record_failure(mirror, older, Error.terminal(:push_rejected, "too late"))

      mirror = Mirroring.get(mirror.id)
      assert mirror.state == "active"
      assert mirror.last_failure == nil
      assert mirror.synced_snapshot_at == newer
    end

    test "a terminal failure disables the mirror with its reason", %{mirror: mirror} do
      :ok =
        Mirroring.record_failure(
          mirror,
          DateTime.utc_now(),
          Error.terminal(:push_rejected, "GH013 secret detected")
        )

      mirror = Mirroring.get(mirror.id)
      assert mirror.state == "disabled"
      assert mirror.disabled_reason == "push_rejected"
      assert mirror.last_failure == "GH013 secret detected"
      assert Mirror.failing?(mirror)
    end

    test "an interrupted sync is recorded with Retry", %{mirror: mirror} do
      :ok = Mirroring.record_interrupted(mirror.id, DateTime.utc_now())

      mirror = Mirroring.get(mirror.id)
      assert mirror.state == "active"
      assert mirror.last_failure =~ "Interrupted"
    end
  end

  describe "repository lifecycle" do
    test "deleting the repository removes the mirror, and never the target", %{mirror: mirror} do
      :ok = Repos.delete("demo")

      assert Mirroring.get(mirror.id) == nil
    end

    test "handing the repository to someone else disables the mirror", %{
      repo: repo,
      mirror: mirror
    } do
      other = user_fixture()
      {:ok, _repo} = Repos.set_owner(repo.name, other.username)

      mirror = Mirroring.get(mirror.id)
      assert mirror.state == "disabled"
      assert mirror.disabled_reason == "owner_changed"
    end
  end

  describe "provider events" do
    test "a removed installation disables the mirrors it served", %{mirror: mirror} do
      :ok =
        Mirroring.handle_event("github", %{
          "type" => "installation_removed",
          "installation_id" => "99"
        })

      mirror = Mirroring.get(mirror.id)
      assert mirror.state == "disabled"
      assert mirror.disabled_reason == "installation_removed"
    end

    test "a target removed from the installation disables its mirror", %{mirror: mirror} do
      :ok =
        Mirroring.handle_event("github", %{
          "type" => "repositories_removed",
          "installation_id" => "99",
          "repository_ids" => ["1234"]
        })

      assert Mirroring.get(mirror.id).disabled_reason == "target_unreachable"
    end

    test "a renamed target keeps its mirror and follows the name", %{mirror: mirror} do
      :ok =
        Mirroring.handle_event("github", %{
          "type" => "repository_renamed",
          "repository_id" => "1234",
          "name" => "octo/renamed",
          "url" => "https://github.test/octo/renamed"
        })

      mirror = Mirroring.get(mirror.id)
      assert mirror.state == "active"
      assert mirror.target_name == "octo/renamed"
    end

    test "an event never enables a disabled mirror", %{mirror: mirror} do
      {:ok, _mirror} = Mirroring.disable(mirror)

      :ok =
        Mirroring.handle_event("github", %{
          "type" => "repository_renamed",
          "repository_id" => "1234",
          "name" => "octo/renamed",
          "url" => "https://github.test/octo/renamed"
        })

      assert Mirroring.get(mirror.id).state == "disabled"
    end

    test "unlinking the account disables the mirrors it connected", %{
      user: user,
      mirror: mirror
    } do
      {:ok, account} = Providers.Accounts.unlink(user, "github")

      assert [job] = all_enqueued(worker: Providers.EventWorker) |> Enum.take(1)
      assert job.args["event"]["type"] == "account_unlinked"

      :ok = Mirroring.handle_event("github", job.args["event"])

      mirror = Mirroring.get(mirror.id)
      assert mirror.state == "disabled"
      assert mirror.disabled_reason == "account_unlinked"
      assert account.login == "octo"
    end
  end
end
