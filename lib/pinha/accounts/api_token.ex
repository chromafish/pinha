defmodule Pinha.Accounts.ApiToken do
  @moduledoc """
  What git sends.

  A git client answers an HTTP Basic challenge and cannot answer a WebAuthn
  one, so clone and push carry one of these instead of a passkey. Shown once
  at creation, stored only as a SHA-256.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Pinha.Accounts.User

  @type t :: %__MODULE__{}

  schema "user_api_tokens" do
    field(:token_hash, :binary)
    field(:label, :string)
    field(:expires_at, :utc_datetime)
    field(:last_used_at, :utc_datetime)

    belongs_to(:user, User)

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @doc "Changeset for a freshly minted token."
  def changeset(token, attrs) do
    token
    |> cast(attrs, [:token_hash, :label, :expires_at, :user_id])
    |> validate_required([:token_hash, :label, :user_id])
    |> validate_length(:label, min: 1, max: 80)
    |> unique_constraint(:token_hash)
  end
end
