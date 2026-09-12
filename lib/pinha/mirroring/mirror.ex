defmodule Pinha.Mirroring.Mirror do
  @moduledoc """
  A repository's one mirror: the repository's `pinha.id`, one target on one
  provider, who connected it with which provider account, its state, and the
  outcome of the last sync. It holds no credentials.

  A mirror is `active`, `awaiting_access` while the provider cannot reach the
  target yet, or `disabled` with a reason. It is behind when the repository
  changed after the snapshot of its last successful sync, or it never
  synced.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Pinha.Accounts.User
  alias Pinha.Providers.Account

  @states ~w(active awaiting_access disabled)
  @reasons ~w(user repository_gone owner_changed account_unlinked access_lost
              installation_removed installation_suspended target_unreachable push_rejected)

  @type t :: %__MODULE__{}

  schema "repo_mirrors" do
    field(:repo_id, :string)
    field(:repo_name, :string)
    field(:provider, :string)
    field(:installation_id, :string)
    field(:target_id, :string)
    field(:target_name, :string)
    field(:target_url, :string)
    field(:target_account_type, :string)
    field(:state, :string)
    field(:disabled_reason, :string)
    field(:held_refs, {:array, :string}, default: [])
    field(:last_written_at, :utc_datetime_usec)
    field(:synced_snapshot_at, :utc_datetime_usec)
    field(:last_synced_at, :utc_datetime)
    field(:last_failed_at, :utc_datetime)
    field(:last_failure, :string)

    belongs_to(:connected_by_user, User)
    belongs_to(:provider_account, Account)

    timestamps(type: :utc_datetime)
  end

  @doc "Every disabled reason the table accepts."
  def reasons, do: @reasons

  @doc "Changeset for a freshly connected mirror."
  def connect_changeset(mirror, attrs) do
    mirror
    |> cast(attrs, [
      :repo_id,
      :repo_name,
      :provider,
      :installation_id,
      :target_id,
      :target_name,
      :target_url,
      :target_account_type,
      :connected_by_user_id,
      :provider_account_id,
      :state
    ])
    |> validate_required([
      :repo_id,
      :repo_name,
      :provider,
      :installation_id,
      :target_id,
      :target_name,
      :target_url,
      :target_account_type,
      :state
    ])
    |> validate_inclusion(:state, @states -- ["disabled"])
    |> validate_inclusion(:target_account_type, ["user", "organization"])
    |> unique_constraint(:repo_id)
    |> unique_constraint([:provider, :target_id])
  end

  @doc "Whether the repository changed after the last successful sync."
  @spec behind?(t()) :: boolean()
  def behind?(%__MODULE__{synced_snapshot_at: nil}), do: true
  def behind?(%__MODULE__{last_written_at: nil}), do: false

  def behind?(%__MODULE__{last_written_at: written, synced_snapshot_at: synced}),
    do: DateTime.compare(written, synced) == :gt

  @doc """
  Whether the latest recorded outcome is a failure: a failure message stays
  until a successful sync clears it.
  """
  @spec failing?(t()) :: boolean()
  def failing?(%__MODULE__{last_failure: failure}), do: not is_nil(failure)
end
