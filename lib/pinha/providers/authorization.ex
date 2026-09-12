defmodule Pinha.Providers.Authorization do
  @moduledoc """
  A pending round trip through a provider's consent screen.

  Only the SHA-256 of the `state` sent to the provider is stored. The row is
  bound to the user who started it, names the handler module that receives
  the result, carries the feature's non-secret parameters, and expires ten
  minutes after it is inserted.
  """

  use Ecto.Schema

  alias Pinha.Accounts.User

  @type t :: %__MODULE__{}

  schema "provider_authorizations" do
    field(:state_hash, :binary)
    field(:provider, :string)
    field(:handler, :string)
    field(:params, :map, default: %{})
    field(:expires_at, :utc_datetime)

    belongs_to(:user, User)

    timestamps(type: :utc_datetime, updated_at: false)
  end
end
