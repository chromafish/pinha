defmodule Pinha.Accounts.Session do
  @moduledoc """
  A browser's proof of a completed sign-in.

  The cookie carries the raw token; only its SHA-256 is stored, so a dump of
  this table cannot be replayed as a login.
  """

  use Ecto.Schema

  alias Pinha.Accounts.User

  @type t :: %__MODULE__{}

  schema "user_sessions" do
    field(:token_hash, :binary)
    field(:last_used_at, :utc_datetime)

    belongs_to(:user, User)

    timestamps(type: :utc_datetime, updated_at: false)
  end
end
