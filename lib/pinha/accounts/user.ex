defmodule Pinha.Accounts.User do
  @moduledoc """
  A person who may reach the server.

  `handle` is what authenticators store as the WebAuthn user handle: 32 opaque
  bytes generated here, never the primary key, so that what a stolen
  authenticator holds says nothing about how many users exist.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Pinha.Accounts.Credential

  @handle_bytes 32

  @type t :: %__MODULE__{}

  schema "users" do
    field(:email, :string)
    field(:handle, :binary)

    has_many(:credentials, Credential)

    timestamps(type: :utc_datetime)
  end

  @doc "Changeset for a new user. The handle is generated, never supplied."
  def changeset(user, attrs) do
    user
    |> cast(attrs, [:email])
    |> validate_required([:email])
    |> update_change(:email, &(&1 |> String.trim() |> String.downcase()))
    |> validate_format(:email, ~r/^[^@,;\s]+@[^@,;\s]+\.[^@,;\s]+$/,
      message: "must be an email address"
    )
    |> validate_length(:email, max: 160)
    |> put_change(:handle, :crypto.strong_rand_bytes(@handle_bytes))
    |> unique_constraint(:email)
  end
end
