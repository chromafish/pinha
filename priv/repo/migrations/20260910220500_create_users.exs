defmodule Pinha.Repo.Migrations.CreateUsers do
  use Ecto.Migration

  def change do
    # `handle` is the WebAuthn user handle: 32 opaque bytes the authenticator
    # stores alongside the passkey. It is deliberately not the primary key, so
    # nothing an authenticator holds reveals how many users exist.
    create table(:users) do
      add :email, :string, null: false
      add :handle, :binary, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:users, [:email])
    create unique_index(:users, [:handle])

    # One row per passkey, one per device. `sign_count` is the authenticator's own counter:
    # a value that fails to advance is the signal that a credential has been
    # cloned, so it is stored rather than recomputed.
    create table(:user_credentials) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :credential_id, :binary, null: false
      add :public_key, :binary, null: false
      add :aaguid, :binary
      add :sign_count, :bigint, null: false, default: 0
      add :label, :string, null: false
      add :last_used_at, :utc_datetime

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create unique_index(:user_credentials, [:credential_id])
    create index(:user_credentials, [:user_id])

    # Browser sessions. The cookie carries 32 random bytes; only their SHA-256
    # is stored, so a dump of this table cannot be replayed as a login.
    create table(:user_sessions) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :token_hash, :binary, null: false
      add :last_used_at, :utc_datetime

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create unique_index(:user_sessions, [:token_hash])
    create index(:user_sessions, [:user_id])

    # What git sends. A passkey cannot answer an HTTP Basic challenge, so
    # clone and push authenticate with a token minted in the UI, hashed here
    # the same way session tokens are.
    create table(:user_api_tokens) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :token_hash, :binary, null: false
      add :label, :string, null: false
      add :expires_at, :utc_datetime
      add :last_used_at, :utc_datetime

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create unique_index(:user_api_tokens, [:token_hash])
    create index(:user_api_tokens, [:user_id])
  end
end
