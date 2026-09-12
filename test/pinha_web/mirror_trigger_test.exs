defmodule PinhaWeb.MirrorTriggerTest do
  @moduledoc "What starts a sync: a write that changed references, and nothing else."

  use PinhaWeb.ConnCase, async: false
  use Oban.Testing, repo: Pinha.Repo

  import Pinha.ProvidersFixtures

  alias Pinha.Mirroring
  alias Pinha.Mirroring.SyncWorker

  setup %{user: user} do
    repo = seed_repo!("demo", [%{message: "first", files: %{"a.txt" => "a\n"}}], user)
    account = github_account_fixture(user)
    mirror = mirror_fixture(repo, user, account)

    %{repo: repo, mirror: mirror, url: authenticated_url(user, "/r/demo.git")}
  end

  test "a push over smart HTTP starts one sync", %{url: url, mirror: mirror} do
    work = tmp_dir!()
    clone = Path.join(work, "clone")
    git!(work, ["clone", "--quiet", url, clone])

    File.write!(Path.join(clone, "b.txt"), "b\n")
    git!(clone, ["add", "-A"])
    git!(clone, ["commit", "--quiet", "-m", "second"])
    git!(clone, ["push", "--quiet", "origin", "main"])

    await_background_tasks()

    assert [job] = all_enqueued(worker: SyncWorker)
    assert job.args["mirror_id"] == mirror.id
    assert job.args["trigger"] == "write"
    assert Mirroring.get(mirror.id).last_written_at
  end

  test "a clone changes nothing and starts nothing", %{url: url, mirror: mirror} do
    work = tmp_dir!()
    git!(work, ["clone", "--quiet", url, Path.join(work, "clone")])

    await_background_tasks()

    assert all_enqueued(worker: SyncWorker) == []
    assert Mirroring.get(mirror.id).last_written_at == nil
  end

  test "a push that git refuses starts nothing", %{repo: repo, url: url, mirror: mirror} do
    work = tmp_dir!()
    clone = Path.join(work, "clone")
    git!(work, ["clone", "--quiet", url, clone])

    # The repository moves on under the client, so its push is not a
    # fast-forward and receive-pack refuses the update.
    other = tmp_dir!()
    git!(File.cwd!(), ["clone", "--quiet", repo.dir, Path.join(other, "other")])
    ahead = Path.join(other, "other")
    File.write!(Path.join(ahead, "c.txt"), "c\n")
    git!(ahead, ["add", "-A"])
    git!(ahead, ["commit", "--quiet", "-m", "ahead"])
    git!(ahead, ["push", "--quiet", "origin", "HEAD:refs/heads/main"])

    File.write!(Path.join(clone, "b.txt"), "b\n")
    git!(clone, ["add", "-A"])
    git!(clone, ["commit", "--quiet", "-m", "second"])

    assert {_out, code} =
             System.cmd("git", ["push", "origin", "main"],
               cd: clone,
               env: [{"GIT_TERMINAL_PROMPT", "0"}],
               stderr_to_stdout: true
             )

    assert code != 0

    await_background_tasks()

    assert all_enqueued(worker: SyncWorker) == []
    assert Mirroring.get(mirror.id).last_written_at == nil
  end
end
