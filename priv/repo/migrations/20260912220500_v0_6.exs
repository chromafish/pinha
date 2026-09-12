defmodule Pinha.Repo.Migrations.V0_6 do
  @moduledoc """
  Username for every user, shown wherever the UI names one.
  """

  use Ecto.Migration

  def up do
    alter table(:users) do
      add :username, :string
    end

    # Backfill existing users (production may already have rows). Use uid suffix
    # to guarantee uniqueness and stay within 64 chars; uid is already unique.
    execute """
    UPDATE users
    SET username = 'user_' || substr(uid, 3, 8)
    WHERE username IS NULL
    """

    execute "ALTER TABLE users ALTER COLUMN username SET NOT NULL"

    create unique_index(:users, [:username])
    create constraint(:users, :username_length, check: "char_length(username) <= 64")
    create constraint(:users, :username_not_blank, check: "char_length(trim(username)) > 0")
  end

  def down do
    drop constraint(:users, :username_not_blank)
    drop constraint(:users, :username_length)
    drop index(:users, [:username])
    alter table(:users) do
      remove :username
    end
  end
end
