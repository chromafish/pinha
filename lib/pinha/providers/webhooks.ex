defmodule Pinha.Providers.Webhooks do
  @moduledoc """
  Receives a provider's webhook deliveries.

  Every delivery is verified by the provider before anything else. A delivery
  ID seen before is ignored. The events a delivery carries are handed to each
  subscriber as its own job, in the transaction that records the delivery, so
  a delivery is either recorded with its jobs or not at all and the provider
  is always answered with success once it is verified.
  """

  alias Pinha.Providers
  alias Pinha.Providers.Delivery
  alias Pinha.Repo

  @doc "Verifies, deduplicates, and dispatches one delivery."
  @spec receive_delivery(module(), %{String.t() => String.t()}, binary()) ::
          :ok | :duplicate | {:error, :invalid_signature | :malformed}
  def receive_delivery(provider, headers, body) do
    with {:ok, delivery_id} <- provider.verify_delivery(headers, body),
         {:ok, payload} <- decode(body) do
      events = provider.events(headers, payload)

      Repo.transaction(fn ->
        %Delivery{provider: provider.name(), delivery_id: delivery_id}
        |> Repo.insert(on_conflict: :nothing, conflict_target: [:provider, :delivery_id])
        |> case do
          {:ok, %Delivery{id: nil}} ->
            :duplicate

          {:ok, _delivery} ->
            Enum.each(events, &Providers.dispatch(provider.name(), &1))
            :ok
        end
      end)
      |> case do
        {:ok, result} -> result
        {:error, _} -> {:error, :malformed}
      end
    end
  end

  defp decode(body) do
    case Jason.decode(body) do
      {:ok, payload} when is_map(payload) -> {:ok, payload}
      _ -> {:error, :malformed}
    end
  end
end
