defmodule Pinha.Repo.Migrations.V0_9 do
  @moduledoc """
  Providers and repository mirroring: linked accounts on another forge,
  pending authorizations, webhook deliveries, mirrors, and Oban's job tables.

  One migration per release. This release is unreleased, so changes to the
  schema are edited into this file rather than stacked behind it.
  """

  use Ecto.Migration

  # The Oban schema version the pinned Oban release requires.
  @oban_version 14

  def up do
    # A user's identity on a provider: its stable user ID and current login.
    # No tokens are stored here or anywhere else.
    create table(:provider_accounts) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :provider, :string, null: false
      add :external_id, :string, null: false
      add :login, :string, null: false

      timestamps(type: :utc_datetime)
    end

    create constraint(:provider_accounts, :provider_accounts_provider_check,
             check: "provider IN ('github')"
           )

    create unique_index(:provider_accounts, [:provider, :external_id])
    create unique_index(:provider_accounts, [:user_id, :provider])

    # One round trip through a provider's consent screen. Only the SHA-256 of
    # the `state` sent to the provider is kept, and the row is deleted when the
    # callback spends it.
    create table(:provider_authorizations) do
      add :state_hash, :binary, null: false
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :provider, :string, null: false
      add :handler, :string, null: false
      add :params, :map, null: false, default: %{}
      add :expires_at, :utc_datetime, null: false

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create constraint(:provider_authorizations, :provider_authorizations_provider_check,
             check: "provider IN ('github')"
           )

    create unique_index(:provider_authorizations, [:state_hash])
    create index(:provider_authorizations, [:expires_at])

    # Delivery IDs already accepted, so a redelivered webhook is ignored.
    create table(:provider_deliveries) do
      add :provider, :string, null: false
      add :delivery_id, :string, null: false

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create constraint(:provider_deliveries, :provider_deliveries_provider_check,
             check: "provider IN ('github')"
           )

    create unique_index(:provider_deliveries, [:provider, :delivery_id])
    create index(:provider_deliveries, [:inserted_at])

    # A repository's one mirror, keyed by the repository's `pinha.id` rather
    # than its name, so a different repository created under the same name
    # never inherits it.
    create table(:repo_mirrors) do
      add :repo_id, :string, null: false
      add :repo_name, :string, null: false
      add :provider, :string, null: false
      add :installation_id, :string, null: false
      add :target_id, :string, null: false
      add :target_name, :string, null: false
      add :target_url, :string, null: false
      add :target_account_type, :string, null: false
      add :connected_by_user_id, references(:users, on_delete: :nilify_all)
      add :provider_account_id, references(:provider_accounts, on_delete: :nilify_all)
      add :state, :string, null: false
      add :disabled_reason, :string
      add :held_refs, {:array, :text}, null: false, default: fragment("'{}'")
      # The two compared to decide whether a mirror is behind keep
      # microseconds, since a write and a snapshot can fall in one second.
      add :last_written_at, :utc_datetime_usec
      add :synced_snapshot_at, :utc_datetime_usec
      add :last_synced_at, :utc_datetime
      add :last_failed_at, :utc_datetime
      add :last_failure, :text

      timestamps(type: :utc_datetime)
    end

    create constraint(:repo_mirrors, :repo_mirrors_provider_check,
             check: "provider IN ('github')"
           )

    create constraint(:repo_mirrors, :repo_mirrors_target_account_type_check,
             check: "target_account_type IN ('user', 'organization')"
           )

    create constraint(:repo_mirrors, :repo_mirrors_state_check,
             check: "state IN ('active', 'awaiting_access', 'disabled')"
           )

    create constraint(:repo_mirrors, :repo_mirrors_disabled_reason_check,
             check:
               "disabled_reason IN ('user', 'repository_gone', 'owner_changed', " <>
                 "'account_unlinked', 'access_lost', 'installation_removed', " <>
                 "'installation_suspended', 'target_unreachable', 'push_rejected')"
           )

    create constraint(:repo_mirrors, :repo_mirrors_disabled_reason_state_check,
             check: "(state = 'disabled') = (disabled_reason IS NOT NULL)"
           )

    create unique_index(:repo_mirrors, [:repo_id])
    create unique_index(:repo_mirrors, [:provider, :target_id])
    create index(:repo_mirrors, [:provider, :installation_id])
    create index(:repo_mirrors, [:provider_account_id])
    create index(:repo_mirrors, [:connected_by_user_id])

    Oban.Migration.up(version: @oban_version)
  end

  def down do
    Oban.Migration.down(version: 1)

    drop table(:repo_mirrors)
    drop table(:provider_deliveries)
    drop table(:provider_authorizations)
    drop table(:provider_accounts)
  end
end
