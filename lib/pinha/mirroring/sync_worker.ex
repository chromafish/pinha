defmodule Pinha.Mirroring.SyncWorker do
  @moduledoc """
  The background job that runs one `Pinha.Mirroring.Sync`.

  Jobs are unique per repository while waiting, so a burst of writes
  collapses into one pending sync; a write during a running sync still gets
  its own. The job runs once, has no timeout, and marks its process
  sensitive, since it holds the target's credential.
  """

  use Oban.Worker,
    queue: :mirrors,
    max_attempts: 1,
    unique: [keys: [:repo_id], states: [:available, :scheduled], period: :infinity]

  alias Pinha.Mirroring
  alias Pinha.Mirroring.Sync
  alias Pinha.Providers

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"mirror_id" => mirror_id, "trigger" => trigger}}) do
    Process.flag(:sensitive, true)

    case Providers.guarded(fn -> Sync.run(mirror_id, trigger) end) do
      {:failed, _kind, _message} -> {:error, "sync failed; the outcome is on the mirror"}
      {:error, error} -> record_crash(mirror_id, error)
      _outcome -> :ok
    end
  end

  defp record_crash(mirror_id, error) do
    if mirror = Mirroring.get(mirror_id) do
      Mirroring.record_failure(mirror, DateTime.utc_now(), error)
    end

    {:error, "sync raised; see the log"}
  end
end
