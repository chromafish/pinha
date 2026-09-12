defmodule Pinha.Providers.PruneWorker do
  @moduledoc """
  Removes expired authorizations and webhook deliveries older than seven
  days, on a schedule.
  """

  use Oban.Worker, queue: :providers, max_attempts: 1

  import Ecto.Query

  alias Pinha.Providers.Authorization
  alias Pinha.Providers.Delivery
  alias Pinha.Repo

  @delivery_days 7

  @impl Oban.Worker
  def perform(_job) do
    now = DateTime.utc_now()
    Repo.delete_all(from(a in Authorization, where: a.expires_at < ^now))

    cutoff = DateTime.add(now, -@delivery_days * 24 * 3600, :second)
    Repo.delete_all(from(d in Delivery, where: d.inserted_at < ^cutoff))
    :ok
  end
end
