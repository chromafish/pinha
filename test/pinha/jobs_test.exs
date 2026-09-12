defmodule Pinha.JobsTest do
  @moduledoc "What a restart does to work that was running when the node stopped."

  use Pinha.DataCase, async: false
  use Pinha.RepoCase, async: false
  use Oban.Testing, repo: Pinha.Repo

  import Ecto.Query
  import Pinha.ProvidersFixtures

  alias Pinha.Jobs
  alias Pinha.Mirroring
  alias Pinha.Mirroring.SyncWorker
  alias Pinha.Repo

  test "an interrupted sync is discarded and shown on its mirror, with Retry" do
    user = user_fixture()
    account = github_account_fixture(user)
    repo = seed_repo!("demo", [%{message: "first", files: %{"a.txt" => "a\n"}}], user)
    mirror = mirror_fixture(repo, user, account)

    {:ok, job} = Mirroring.enqueue_sync(mirror, "write")

    Repo.update_all(from(j in Oban.Job, where: j.id == ^job.id),
      set: [state: "executing", attempted_at: DateTime.utc_now()]
    )

    assert Jobs.discard_interrupted() == 1

    assert Repo.get(Oban.Job, job.id).state == "discarded"
    assert all_enqueued(worker: SyncWorker) == []

    mirror = Mirroring.get(mirror.id)
    assert mirror.state == "active"
    assert mirror.last_failure =~ "Interrupted by a restart"
  end

  test "a job that was only waiting is left alone" do
    user = user_fixture()
    account = github_account_fixture(user)
    repo = seed_repo!("demo", [%{message: "first", files: %{"a.txt" => "a\n"}}], user)
    mirror = mirror_fixture(repo, user, account)

    {:ok, job} = Mirroring.enqueue_sync(mirror, "write")

    assert Jobs.discard_interrupted() == 0
    assert Repo.get(Oban.Job, job.id).state == "available"
    assert Mirroring.get(mirror.id).last_failure == nil
  end
end
