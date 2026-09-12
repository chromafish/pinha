defmodule Pinha.Providers.Delivery do
  @moduledoc """
  A webhook delivery already accepted, kept for seven days so a redelivery
  of the same ID is ignored.
  """

  use Ecto.Schema

  @type t :: %__MODULE__{}

  schema "provider_deliveries" do
    field(:provider, :string)
    field(:delivery_id, :string)

    timestamps(type: :utc_datetime, updated_at: false)
  end
end
