defmodule Pinha.Accounts.Credential do
  @moduledoc """
  One passkey.

  The COSE key `wax_` returns is a map, stored here as an Erlang term because
  the server both writes and reads it; `sign_count` is the authenticator's own
  counter, kept so that a counter which fails to advance can be caught.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Pinha.Accounts.User

  @type t :: %__MODULE__{}

  schema "user_credentials" do
    field(:credential_id, :binary)
    field(:public_key, :binary)
    field(:aaguid, :binary)
    field(:sign_count, :integer, default: 0)
    field(:label, :string)
    field(:last_used_at, :utc_datetime)

    belongs_to(:user, User)

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @doc "Changeset for a passkey registered by a completed ceremony."
  def changeset(credential, attrs) do
    credential
    |> cast(attrs, [:credential_id, :public_key, :aaguid, :sign_count, :label, :user_id])
    |> validate_required([:credential_id, :public_key, :label, :user_id])
    |> validate_length(:label, min: 1, max: 80)
    |> unique_constraint(:credential_id)
  end

  @doc "Encodes a COSE key for storage."
  def encode_key(cose_key), do: :erlang.term_to_binary(cose_key)

  @doc "Decodes a stored COSE key. Safe because only this module writes them."
  def decode_key(binary), do: :erlang.binary_to_term(binary, [:safe])
end
