defmodule Pinha.Jobs do
  @moduledoc """
  Background work in Postgres, on Oban.

  Jobs run once and are never retried automatically: a failure is shown to a
  person, who retries when they choose. A job left `executing` by a restart
  is discarded at boot and its work is recorded as interrupted, since nothing
  is running it any more.
  """

  use GenServer

  import Ecto.Query

  alias Pinha.Mirroring
  alias Pinha.Mirroring.SyncWorker
  alias Pinha.Repo

  require Logger

  @doc """
  Discards jobs left `executing` by a restart, before the queues start.

  Started as a supervised child that does its work and stops: this node runs
  every queue, so anything still marked executing belongs to a node that is
  gone.
  """
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    if Application.get_env(:pinha, :discard_interrupted_jobs, true), do: discard_interrupted()
    :ignore
  end

  @doc "Discards every executing job and records what each interrupted."
  @spec discard_interrupted() :: non_neg_integer()
  def discard_interrupted do
    now = DateTime.utc_now()

    {_count, jobs} =
      from(j in Oban.Job,
        where: j.state == "executing",
        select: j,
        update: [
          set: [state: "discarded", discarded_at: ^DateTime.truncate(now, :microsecond)]
        ]
      )
      |> Repo.update_all([])

    Enum.each(jobs, &record_interrupted/1)
    length(jobs)
  rescue
    error ->
      Logger.error("discarding interrupted jobs failed: #{inspect(error.__struct__)}")
      0
  end

  @sync_worker inspect(SyncWorker)

  defp record_interrupted(%Oban.Job{worker: @sync_worker, args: args} = job) do
    case args do
      %{"mirror_id" => mirror_id} ->
        Mirroring.record_interrupted(mirror_id, job.attempted_at || job.inserted_at)

      _ ->
        :ok
    end
  end

  defp record_interrupted(_job), do: :ok
end
