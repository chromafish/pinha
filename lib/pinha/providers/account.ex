defmodule Pinha.Providers.Account do
  @moduledoc """
  A Pinha user's identity on a provider: the provider's stable user ID and the
  login it last reported. It holds no tokens.

  A user links at most one account per provider, and an identity links to at
  most one user. Relinking to a different identity deletes this row and
  inserts a new one, so features that recorded the old `id` notice.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Pinha.Accounts.User

  @type t :: %__MODULE__{}

  schema "provider_accounts" do
    field(:provider, :string)
    field(:external_id, :string)
    field(:login, :string)

    belongs_to(:user, User)

    timestamps(type: :utc_datetime)
  end

  @doc "Changeset for linking an identity to a user."
  def changeset(account, attrs) do
    account
    |> cast(attrs, [:user_id, :provider, :external_id, :login])
    |> validate_required([:user_id, :provider, :external_id, :login])
    |> check_constraint(:provider, name: :provider_accounts_provider_check)
    |> unique_constraint([:provider, :external_id])
    |> unique_constraint([:user_id, :provider])
  end
end
