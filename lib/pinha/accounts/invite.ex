defmodule Pinha.Accounts.Invite do
  @moduledoc """
  What admits a registration.

  An admin mints one in the UI and hands it over by whatever channel they
  already have with the person, because the server delivers no mail. Shown
  once at creation, stored only as a SHA-256, and spent by the registration it
  admits.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Pinha.Accounts.User

  @type t :: %__MODULE__{}

  schema "user_invites" do
    field(:token_hash, :binary)
    field(:label, :string)
    field(:expires_at, :utc_datetime)
    field(:consumed_at, :utc_datetime)

    belongs_to(:created_by, User, foreign_key: :created_by_user_id)
    belongs_to(:consumed_by, User, foreign_key: :consumed_by_user_id)

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @doc "Changeset for a freshly minted invite."
  def changeset(invite, attrs) do
    invite
    |> cast(attrs, [:token_hash, :label, :expires_at, :created_by_user_id])
    |> validate_required([:token_hash, :label, :expires_at, :created_by_user_id])
    |> validate_length(:label, min: 1, max: 80)
    |> unique_constraint(:token_hash)
  end
end
