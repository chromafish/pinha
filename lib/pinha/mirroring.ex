defmodule Pinha.Mirroring do
  @moduledoc """
  One-way mirrors of repositories to another forge.

  A mirror follows a repository's `pinha.id`, not its name, and holds no
  credentials. Everything provider-specific goes through the provider's
  `Pinha.Mirroring.Capability`; this module owns the rules: who may do what,
  the connection check every enable and sync runs, when a sync starts, how
  its outcome is recorded, and what provider events do to a mirror.
  """

  @behaviour Pinha.Providers.EventSubscriber

  import Ecto.Query

  alias Pinha.Accounts
  alias Pinha.Accounts.User
  alias Pinha.Mirroring.Capability
  alias Pinha.Mirroring.Mirror
  alias Pinha.Mirroring.SyncWorker
  alias Pinha.Providers
  alias Pinha.Providers.Account
  alias Pinha.Providers.Authorizations
  alias Pinha.Providers.Error
  alias Pinha.Repo
  alias Pinha.Repos
  alias Pinha.Repos.Repo, as: Repository

  require Logger

  @locks Pinha.Mirroring.Locks
  @github_name ~r/\A[A-Za-z0-9._-]{1,100}\z/

  ## Reading

  @doc "One mirror by ID, or nil."
  @spec get(integer()) :: Mirror.t() | nil
  def get(id), do: Repo.get(Mirror, id)

  @doc "The repository's mirror, or nil. A repository without an ID has none."
  @spec for_repo(Repository.t()) :: Mirror.t() | nil
  def for_repo(%Repository{id: nil}), do: nil
  def for_repo(%Repository{id: id}), do: Repo.get_by(Mirror, repo_id: id)

  @doc "Whether mirroring can be offered at all: some configured provider implements it."
  @spec available?() :: boolean()
  def available?, do: Providers.with_capability(Capability) != []

  @doc "The owner or an admin manages a mirror; only the owner connects one."
  @spec may_manage?(Repository.t(), User.t() | nil) :: boolean()
  def may_manage?(repo, user), do: Repos.writable_by?(repo, user)

  @doc "Whether `user` may connect a mirror for `repo`."
  @spec may_connect?(Repository.t(), User.t() | nil) :: boolean()
  def may_connect?(%Repository{owner_uid: uid}, %User{uid: uid}) when is_binary(uid), do: true
  def may_connect?(_repo, _user), do: false

  ## Writes and triggers

  @doc """
  Records a reference-changing write and starts a sync for an active mirror.

  Runs off the writer's process: a write never waits for its sync, and a
  failing mirror never fails a write.
  """
  @spec after_write(Repository.t()) :: :ok
  def after_write(%Repository{id: nil}), do: :ok

  def after_write(%Repository{} = repo) do
    Task.Supervisor.start_child(Pinha.TaskSupervisor, fn -> written(repo) end)
    :ok
  end

  @doc "The body of `after_write/1`, run in the calling process."
  @spec written(Repository.t()) :: :ok
  def written(%Repository{id: nil}), do: :ok

  def written(%Repository{id: id}) do
    now = DateTime.utc_now()

    # Two writes finishing close together may record out of order; the later
    # time wins.
    {_count, mirrors} =
      from(m in Mirror,
        where: m.repo_id == ^id,
        select: m,
        update: [set: [last_written_at: fragment("GREATEST(?, ?)", m.last_written_at, ^now)]]
      )
      |> Repo.update_all([])

    for %Mirror{state: "active"} = mirror <- mirrors, do: enqueue_sync(mirror, "write")
    :ok
  rescue
    error ->
      Logger.warning("recording a write for mirroring failed: #{inspect(error.__struct__)}")
      :ok
  end

  @doc """
  Enqueues a sync. While one is already waiting for the repository, that one
  is returned instead.
  """
  @spec enqueue_sync(Mirror.t(), String.t()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue_sync(%Mirror{} = mirror, trigger) do
    %{"mirror_id" => mirror.id, "repo_id" => mirror.repo_id, "trigger" => trigger}
    |> SyncWorker.new()
    |> Oban.insert()
  end

  @doc """
  Runs `fun` while holding the repository's sync lock, waiting for a sync
  already holding it to finish.
  """
  @spec with_sync_lock(String.t(), (-> result)) :: result when result: term()
  def with_sync_lock(repo_id, fun) do
    case Registry.register(@locks, repo_id, nil) do
      {:ok, _owner} ->
        try do
          fun.()
        after
          Registry.unregister(@locks, repo_id)
        end

      {:error, {:already_registered, holder}} ->
        ref = Process.monitor(holder)

        receive do
          {:DOWN, ^ref, :process, ^holder, _reason} -> :ok
        end

        with_sync_lock(repo_id, fun)
    end
  end

  ## The connection check

  @doc """
  Checks the parts of the connection Pinha knows: the repository with the
  mirror's ID still exists under its name, its owner is still the user who
  connected it, and that user's provider account is still the one it was
  connected with. The provider checks the user's access to the target in
  `prepare_sync/2`.
  """
  @spec check_connection(Mirror.t()) ::
          {:ok, Repository.t(), Account.t(), module()} | {:error, Error.t()}
  def check_connection(%Mirror{} = mirror) do
    with {:ok, capability} <- capability(mirror.provider),
         {:ok, repo} <- repository(mirror),
         {:ok, user} <- connecting_owner(mirror, repo),
         {:ok, account} <- connecting_account(mirror, user) do
      {:ok, repo, account, capability}
    end
  end

  defp capability(provider) do
    case Providers.capability(provider, Capability) do
      {:ok, capability} -> {:ok, capability}
      :error -> {:error, Error.transient("the #{provider} provider is not configured")}
    end
  end

  defp repository(mirror) do
    case Repos.fetch(mirror.repo_name) do
      {:ok, %Repository{id: id} = repo} when id == mirror.repo_id ->
        {:ok, repo}

      {:ok, _other} ->
        {:error,
         Error.terminal(:repository_gone, "#{mirror.repo_name} is now a different repository")}

      {:error, :not_found} ->
        {:error, Error.terminal(:repository_gone, "#{mirror.repo_name} no longer exists")}

      {:error, _unavailable} ->
        {:error, Error.transient("#{mirror.repo_name} is unavailable")}
    end
  end

  defp connecting_owner(%Mirror{connected_by_user_id: nil}, _repo),
    do: {:error, Error.terminal(:owner_changed, "the user who connected the mirror is gone")}

  defp connecting_owner(mirror, repo) do
    case Accounts.fetch_user_by_uid(repo.owner_uid) do
      {:ok, %User{id: id} = user} when id == mirror.connected_by_user_id ->
        {:ok, user}

      _ ->
        {:error,
         Error.terminal(:owner_changed, "the repository's owner is no longer who connected it")}
    end
  end

  defp connecting_account(%Mirror{provider_account_id: nil}, _user),
    do: {:error, Error.terminal(:account_unlinked, "the connecting account was unlinked")}

  defp connecting_account(mirror, user) do
    case Providers.Accounts.get(user, mirror.provider) do
      %Account{id: id} = account when id == mirror.provider_account_id ->
        {:ok, account}

      _ ->
        {:error, Error.terminal(:account_unlinked, "the connecting account was unlinked")}
    end
  end

  ## Outcomes

  @doc """
  Records a successful sync of `snapshot`, unless a sync of a newer snapshot
  already recorded success.
  """
  @spec record_success(Mirror.t(), Repos.Snapshot.t(), [String.t()], map()) :: :ok
  def record_success(%Mirror{} = mirror, snapshot, held, push) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    mirror
    |> not_superseded(snapshot.taken_at)
    |> Repo.update_all(
      set: [
        synced_snapshot_at: snapshot.taken_at,
        last_synced_at: now,
        last_failure: nil,
        held_refs: held,
        target_name: push.target_name,
        target_url: push.target_url,
        updated_at: now
      ]
    )

    :ok
  end

  @doc """
  Records a failed sync of what the repository held at `at`, unless a sync of
  a newer snapshot already recorded success. A terminal failure also disables
  the mirror with its reason, when nothing disabled it first.
  """
  @spec record_failure(Mirror.t(), DateTime.t(), Error.t()) :: :ok
  def record_failure(%Mirror{} = mirror, at, %Error{} = error) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Repo.transaction(fn ->
      {count, _} =
        mirror
        |> not_superseded(at)
        |> Repo.update_all(
          set: [last_failed_at: now, last_failure: error.message, updated_at: now]
        )

      if count == 1 and error.kind == :terminal do
        disable_query(from(m in Mirror, where: m.id == ^mirror.id), reason(error))
      end
    end)

    :ok
  end

  defp not_superseded(mirror, at) do
    from(m in Mirror,
      where: m.id == ^mirror.id,
      where: is_nil(m.synced_snapshot_at) or m.synced_snapshot_at < ^at
    )
  end

  defp reason(%Error{reason: reason}) do
    name = to_string(reason)
    if name in Mirror.reasons(), do: name, else: "target_unreachable"
  end

  @doc "Records that a sync which began at `attempted_at` was interrupted by a restart."
  @spec record_interrupted(integer(), DateTime.t()) :: :ok
  def record_interrupted(mirror_id, attempted_at) do
    case get(mirror_id) do
      nil -> :ok
      mirror -> record_failure(mirror, attempted_at, Error.transient("Interrupted by a restart."))
    end
  end

  ## Repository lifecycle

  @doc "Disables the repository's mirror with `reason`, if it has an enabled one."
  @spec disable_for_repo(Repository.t(), atom()) :: :ok | {:error, :failed}
  def disable_for_repo(%Repository{id: nil}, _reason), do: :ok

  def disable_for_repo(%Repository{id: id}, reason) do
    disable_query(from(m in Mirror, where: m.repo_id == ^id), Atom.to_string(reason))
    :ok
  rescue
    error ->
      Logger.error("disabling the mirror of #{id} failed: #{inspect(error.__struct__)}")
      {:error, :failed}
  end

  @doc "Removes the mirror of the repository with this ID. The target is untouched."
  @spec delete_for_repo_id(String.t()) :: :ok
  def delete_for_repo_id(id) do
    Repo.delete_all(from(m in Mirror, where: m.repo_id == ^id))
    :ok
  end

  defp disable_query(query, reason) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    query
    |> where([m], m.state != "disabled")
    |> Repo.update_all(set: [state: "disabled", disabled_reason: reason, updated_at: now])
  end

  ## Connecting

  @doc """
  Starts connecting `repo` to a target on `provider_name` for its owner.

  Returns the provider URL to send the browser to, or a message saying why
  not.
  """
  @spec start_connect(User.t(), Repository.t(), String.t(), map()) ::
          {:ok, String.t()} | {:error, String.t()}
  def start_connect(%User{} = user, %Repository{} = repo, provider_name, params) do
    with :ok <- check(may_connect?(repo, user), "Only the repository's owner connects a mirror."),
         {:ok, provider} <- fetch_provider(provider_name),
         {:ok, capability} <- fetch_capability(provider),
         {:ok, account} <- linked_account(user, provider),
         {:ok, repo} <- with_id(repo),
         :ok <- check(is_nil(for_repo(repo)), "This repository already has a mirror."),
         {:ok, choice} <- connect_choice(params),
         {:ok, url_opts} <- authorization_options(capability, account, choice) do
      stored =
        Map.merge(choice, %{
          "repo_name" => repo.name,
          "repo_id" => repo.id,
          "return_to" => "/r/#{repo.name}"
        })

      case Authorizations.start(user, provider, Pinha.Mirroring.ConnectHandler, stored, url_opts) do
        {:ok, url} -> {:ok, url}
        {:error, _changeset} -> {:error, "Could not start the authorization."}
      end
    end
  end

  defp check(true, _message), do: :ok
  defp check(false, message), do: {:error, message}

  defp fetch_provider(name) do
    case Providers.fetch(name) do
      {:ok, provider} -> {:ok, provider}
      :error -> {:error, "That provider is not configured."}
    end
  end

  defp fetch_capability(provider) do
    case Providers.capability(provider, Capability) do
      {:ok, capability} -> {:ok, capability}
      :error -> {:error, "#{provider.label()} does not support mirroring."}
    end
  end

  defp linked_account(user, provider) do
    case Providers.Accounts.get(user, provider.name()) do
      nil -> {:error, "Link your #{provider.label()} account in settings first."}
      account -> {:ok, account}
    end
  end

  defp with_id(repo) do
    case Repos.ensure_id(repo) do
      {:ok, repo} -> {:ok, repo}
      {:error, _} -> {:error, "Could not record the repository's ID."}
    end
  end

  # A new repository is private with issues, projects, and wiki off unless
  # the form says otherwise; an existing one must be confirmed, since its
  # branches and tags will be replaced.
  defp connect_choice(params) do
    account = params |> Map.get("account", "") |> to_string() |> String.trim()
    name = params |> Map.get("name", "") |> to_string() |> String.trim()
    mode = Map.get(params, "mode")

    cond do
      not Regex.match?(~r/\A[A-Za-z0-9-]{1,39}\z/, account) ->
        {:error, "Choose the account to mirror to."}

      not Regex.match?(@github_name, name) or name in [".", ".."] ->
        {:error, "Choose a valid repository name."}

      mode == "existing" and Map.get(params, "confirm") != "true" ->
        {:error, "Confirm that the existing repository's branches and tags will be replaced."}

      mode == "existing" ->
        {:ok, %{"account" => account, "name" => name, "mode" => "existing"}}

      mode == "new" ->
        {:ok,
         %{
           "account" => account,
           "name" => name,
           "mode" => "new",
           "private" => Map.get(params, "private", "true") == "true",
           "has_issues" => Map.get(params, "has_issues") == "true",
           "has_projects" => Map.get(params, "has_projects") == "true",
           "has_wiki" => Map.get(params, "has_wiki") == "true"
         }}

      true ->
        {:error, "Choose a new or an existing repository."}
    end
  end

  defp authorization_options(capability, account, choice) do
    case Providers.sensitive(fn -> capability.authorization_options(account, choice) end) do
      {:ok, opts} -> {:ok, opts}
      {:error, %Error{message: message}} -> {:error, message}
    end
  end

  @doc """
  Records a mirror a connect produced, and starts its first sync when it is
  active.
  """
  @spec create(Repository.t(), User.t(), Account.t(), Capability.target()) ::
          {:ok, Mirror.t()} | {:error, Ecto.Changeset.t()}
  def create(repo, user, account, target) do
    attrs =
      Map.merge(target, %{
        repo_id: repo.id,
        repo_name: repo.name,
        provider: account.provider,
        connected_by_user_id: user.id,
        provider_account_id: account.id
      })

    with {:ok, mirror} <- %Mirror{} |> Mirror.connect_changeset(attrs) |> Repo.insert() do
      if mirror.state == "active", do: enqueue_sync(mirror, "connected")
      {:ok, mirror}
    end
  end

  ## Controls

  @doc """
  Enables a mirror after the connection check passes, and starts a sync.

  A mirror that fails the check stays disabled, so an admin cannot push under
  someone else's access by enabling it.
  """
  @spec enable(Mirror.t()) :: {:ok, Mirror.t()} | {:error, String.t()}
  def enable(%Mirror{state: "disabled"} = mirror) do
    case Providers.sensitive(fn -> verify(mirror) end) do
      :ok ->
        mirror = update!(mirror, state: "active", disabled_reason: nil)
        enqueue_sync(mirror, "enabled")
        {:ok, mirror}

      {:error, %Error{kind: :terminal} = error} ->
        update!(mirror, disabled_reason: reason(error), last_failure: error.message)
        {:error, error.message}

      {:error, %Error{message: message}} ->
        {:error, message}
    end
  end

  def enable(%Mirror{}), do: {:error, "The mirror is not disabled."}

  @doc "Disables a mirror. The target is untouched."
  @spec disable(Mirror.t()) :: {:ok, Mirror.t()}
  def disable(%Mirror{} = mirror) do
    {:ok, update!(mirror, state: "disabled", disabled_reason: "user")}
  end

  @doc "Removes a mirror. The target is untouched."
  @spec disconnect(Mirror.t()) :: :ok
  def disconnect(%Mirror{} = mirror) do
    Repo.delete_all(from(m in Mirror, where: m.id == ^mirror.id))
    :ok
  end

  @doc "Starts a sync of an active mirror now, for Sync now and Retry."
  @spec sync_now(Mirror.t(), String.t()) :: {:ok, Oban.Job.t()} | {:error, String.t()}
  def sync_now(mirror, trigger \\ "manual")

  def sync_now(%Mirror{state: "active"} = mirror, trigger) do
    case enqueue_sync(mirror, trigger) do
      {:ok, job} -> {:ok, job}
      {:error, _} -> {:error, "Could not start a sync."}
    end
  end

  def sync_now(%Mirror{}, _trigger), do: {:error, "Only an active mirror syncs."}

  @doc """
  Checks again whether the provider can reach a mirror awaiting access, and
  activates it when it can.
  """
  @spec check_again(Mirror.t()) :: {:ok, Mirror.t()} | {:error, String.t()}
  def check_again(%Mirror{state: "awaiting_access"} = mirror) do
    case Providers.sensitive(fn -> verify(mirror) end) do
      :ok ->
        mirror = update!(mirror, state: "active", last_failure: nil)
        enqueue_sync(mirror, "access_granted")
        {:ok, mirror}

      {:error, %Error{reason: :target_unreachable, message: message}} ->
        {:error, message}

      {:error, %Error{kind: :terminal} = error} ->
        update!(mirror,
          state: "disabled",
          disabled_reason: reason(error),
          last_failure: error.message
        )

        {:error, error.message}

      {:error, %Error{message: message}} ->
        {:error, message}
    end
  end

  def check_again(%Mirror{}), do: {:error, "The mirror is not awaiting access."}

  defp verify(mirror) do
    with {:ok, _repo, account, capability} <- check_connection(mirror),
         {:ok, _push} <- capability.prepare_sync(mirror, account) do
      :ok
    end
  end

  @doc "Where the owner grants the provider access to the target."
  @spec access_settings_url(Mirror.t()) :: String.t() | nil
  def access_settings_url(%Mirror{} = mirror) do
    case Providers.capability(mirror.provider, Capability) do
      {:ok, capability} -> capability.access_settings_url(mirror)
      :error -> nil
    end
  end

  defp update!(mirror, changes) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    mirror
    |> Ecto.Changeset.change(Keyword.put(changes, :updated_at, now))
    |> Repo.update!()
  end

  ## Provider events

  @doc """
  Disables mirrors a provider event says can no longer sync, and follows a
  renamed target. Events never enable a mirror.
  """
  @impl Providers.EventSubscriber
  def handle_event(provider, %{"type" => "installation_removed", "installation_id" => id}),
    do: disable_installation(provider, id, "installation_removed")

  def handle_event(provider, %{"type" => "installation_suspended", "installation_id" => id}),
    do: disable_installation(provider, id, "installation_suspended")

  def handle_event(provider, %{
        "type" => "repositories_removed",
        "installation_id" => installation_id,
        "repository_ids" => ids
      }) do
    from(m in Mirror,
      where:
        m.provider == ^provider and m.installation_id == ^installation_id and
          m.target_id in ^ids
    )
    |> disable_query("target_unreachable")

    :ok
  end

  def handle_event(provider, %{"type" => type, "repository_id" => id})
      when type in ["repository_deleted", "repository_transferred"] do
    from(m in Mirror, where: m.provider == ^provider and m.target_id == ^id)
    |> disable_query("target_unreachable")

    :ok
  end

  def handle_event(provider, %{"type" => "repository_renamed", "repository_id" => id} = event) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    from(m in Mirror, where: m.provider == ^provider and m.target_id == ^id)
    |> Repo.update_all(
      set: [target_name: event["name"], target_url: event["url"], updated_at: now]
    )

    :ok
  end

  # The account row is already gone, and deleting it cleared the mirror's
  # reference to it, so a mirror connected by the same user with no account
  # left is the one it named.
  def handle_event(provider, %{
        "type" => "account_unlinked",
        "account_id" => account_id,
        "user_id" => user_id
      }) do
    from(m in Mirror,
      where: m.provider == ^provider,
      where:
        m.provider_account_id == ^account_id or
          (is_nil(m.provider_account_id) and m.connected_by_user_id == ^user_id)
    )
    |> disable_query("account_unlinked")

    :ok
  end

  def handle_event(_provider, _event), do: :ok

  defp disable_installation(provider, installation_id, reason) do
    from(m in Mirror, where: m.provider == ^provider and m.installation_id == ^installation_id)
    |> disable_query(reason)

    :ok
  end
end
