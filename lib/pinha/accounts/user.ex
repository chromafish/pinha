defmodule Pinha.Accounts.User do
  @moduledoc """
  A person who may reach the server.

  `handle` is what authenticators store as the WebAuthn user handle: 32 opaque
  bytes generated here, never the primary key, so that what a stolen
  authenticator holds says nothing about how many users exist.

  `uid` is how everything outside this database names a user: a repository
  records its owner as `pinha.owner` in its own git config, and that is a
  `uid`. It is generated once and never changes, so an email a user edits or a
  passkey they replace moves nothing that points at them, and it is opaque so
  that a file on disk gives away neither how many users exist nor the order
  they arrived in.

  `admin` is true for the user who claimed the server, and for anyone the
  operator promotes from the release console. Admins mint the invites every
  other account arrives on.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Pinha.Accounts.Credential

  @handle_bytes 32
  @uid_bytes 16
  @uid_prefix "u_"

  @type t :: %__MODULE__{}

  schema "users" do
    field(:email, :string)
    field(:uid, :string)
    field(:handle, :binary)
    field(:admin, :boolean, default: false)

    has_many(:credentials, Credential)

    timestamps(type: :utc_datetime)
  end

  @doc "A fresh `uid`: an opaque name for one user, safe to write to disk."
  @spec generate_uid() :: String.t()
  def generate_uid do
    @uid_prefix <>
      (@uid_bytes
       |> :crypto.strong_rand_bytes()
       |> Base.encode32(padding: false, case: :lower))
  end

  @doc "Changeset for a new user. The handle and uid are generated, never supplied."
  def changeset(user, attrs) do
    user
    |> cast(attrs, [:email, :admin])
    |> validate_required([:email])
    |> update_change(:email, &(&1 |> String.trim() |> String.downcase()))
    |> validate_format(:email, ~r/^[^@,;\s]+@[^@,;\s]+\.[^@,;\s]+$/,
      message: "must be an email address"
    )
    |> validate_length(:email, max: 160)
    |> put_change(:handle, :crypto.strong_rand_bytes(@handle_bytes))
    |> put_change(:uid, generate_uid())
    |> unique_constraint(:email)
    |> unique_constraint(:uid)
  end
end
