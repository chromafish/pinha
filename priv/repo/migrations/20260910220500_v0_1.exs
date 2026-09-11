defmodule Pinha.Repo.Migrations.V0_1 do
  @moduledoc """
  Everything the database holds at v0.1: who may reach the server.

  One migration per release. This release is unreleased, so changes to the
  schema are edited into this file rather than stacked behind it; the next one
  gets its own file once v0.1 is tagged.
  """

  use Ecto.Migration

  def change do
    # `handle` is the WebAuthn user handle: 32 opaque bytes the authenticator
    # stores alongside the passkey. It is deliberately not the primary key, so
    # nothing an authenticator holds reveals how many users exist. `admin` is
    # true for whoever claimed the server, and minting invites is what it buys.
    # `uid` is what the rest of the system stores when it names a user
    # outside this database: repository ownership lives in each repo's git
    # config as `pinha.owner`. It is neither the email, which changes, nor the
    # row id, which counts users to anyone who reads one.
    create table(:users) do
      add(:email, :string, null: false)
      add(:uid, :string, null: false)
      add(:handle, :binary, null: false)
      add(:admin, :boolean, null: false, default: false)

      timestamps(type: :utc_datetime)
    end

    create(unique_index(:users, [:email]))
    create(unique_index(:users, [:uid]))
    create(unique_index(:users, [:handle]))

    # One row per passkey, one per device. `sign_count` is the authenticator's own counter:
    # a value that fails to advance is the signal that a credential has been
    # cloned, so it is stored rather than recomputed.
    create table(:user_credentials) do
      add(:user_id, references(:users, on_delete: :delete_all), null: false)
      add(:credential_id, :binary, null: false)
      add(:public_key, :binary, null: false)
      add(:aaguid, :binary)
      add(:sign_count, :bigint, null: false, default: 0)
      add(:label, :string, null: false)
      add(:last_used_at, :utc_datetime)

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create(unique_index(:user_credentials, [:credential_id]))
    create(index(:user_credentials, [:user_id]))

    # Browser sessions. The cookie carries 32 random bytes; only their SHA-256
    # is stored, so a dump of this table cannot be replayed as a login.
    create table(:user_sessions) do
      add(:user_id, references(:users, on_delete: :delete_all), null: false)
      add(:token_hash, :binary, null: false)
      add(:last_used_at, :utc_datetime)

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create(unique_index(:user_sessions, [:token_hash]))
    create(index(:user_sessions, [:user_id]))

    # What git sends. A passkey cannot answer an HTTP Basic challenge, so
    # clone and push authenticate with a token minted in the UI, hashed here
    # the same way session tokens are.
    create table(:user_api_tokens) do
      add(:user_id, references(:users, on_delete: :delete_all), null: false)
      add(:token_hash, :binary, null: false)
      add(:label, :string, null: false)
      add(:expires_at, :utc_datetime)
      add(:last_used_at, :utc_datetime)

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create(unique_index(:user_api_tokens, [:token_hash]))
    create(index(:user_api_tokens, [:user_id]))

    # What admits a registration on a server that already has users. Hashed
    # the way an API token is, spent by the registration it admits, and kept
    # afterwards so settings can show who invited whom.
    create table(:user_invites) do
      add(:token_hash, :binary, null: false)
      add(:label, :string, null: false)
      add(:created_by_user_id, references(:users, on_delete: :delete_all), null: false)
      add(:consumed_by_user_id, references(:users, on_delete: :delete_all))
      add(:expires_at, :utc_datetime, null: false)
      add(:consumed_at, :utc_datetime)

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create(unique_index(:user_invites, [:token_hash]))
    create(index(:user_invites, [:created_by_user_id]))

    # What git presents over SSH. The fingerprint is unique across every user,
    # so one key cannot belong to two people, and authentication is the same
    # single indexed read a token gets.
    create table(:user_ssh_keys) do
      add(:user_id, references(:users, on_delete: :delete_all), null: false)
      add(:fingerprint, :binary, null: false)
      add(:public_key, :text, null: false)
      add(:algorithm, :string, null: false)
      add(:label, :string, null: false)
      add(:last_used_at, :utc_datetime)

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create(unique_index(:user_ssh_keys, [:fingerprint]))
    create(index(:user_ssh_keys, [:user_id]))
  end
end
