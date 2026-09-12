defmodule Pinha.Providers.EventWorker do
  @moduledoc """
  Delivers one provider event to one subscriber.

  The subscriber is named in the job and looked up among the configured
  subscribers, so a job can only ever call a module that subscribes. It runs
  once: a failing subscriber is recorded on its job and affects no other.
  """

  use Oban.Worker, queue: :providers, max_attempts: 1

  alias Pinha.Providers

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"provider" => provider, "subscriber" => name, "event" => event}}) do
    case Enum.find(Providers.subscribers(), &(inspect(&1) == name)) do
      nil -> {:cancel, "#{name} does not subscribe to provider events"}
      subscriber -> subscriber.handle_event(provider, event)
    end
  end
end
