defmodule Pinha.Providers.EventSubscriber do
  @moduledoc """
  What a feature implements to hear about provider events.

  Each event reaches each subscriber in its own background job, so one
  failing subscriber affects no other. Events only let a feature notice
  sooner: they never grant access.
  """

  @doc "Handles one event from the provider named `provider`."
  @callback handle_event(provider :: String.t(), event :: map()) :: :ok | {:error, term()}
end
