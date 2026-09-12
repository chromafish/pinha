defmodule Pinha.Repos.Creator do
  @moduledoc """
  Serializes create and delete so the repo root never shows a half-built repo.

  Create initializes into a temporary directory and atomically renames it into
  place; delete renames out of the listing and removes the leftovers in a
  supervised background task.
  """

  use GenServer

  alias Pinha.Config
  alias Pinha.Git
  alias Pinha.Repos
  alias Pinha.Repos.Repo

  require Logger

  @tmp_prefix ".tmp-create-"
  @trash_prefix ".deleted-"

  def start_link(opts),
    do: GenServer.start_link(__MODULE__, :ok, Keyword.put_new(opts, :name, __MODULE__))

  @spec create(String.t(), String.t() | nil) :: {:ok, Repo.t()} | {:error, :exists | :failed}
  def create(name, owner_uid \\ nil),
    do: GenServer.call(__MODULE__, {:create, name, owner_uid}, 30_000)

  @spec delete(String.t()) :: :ok | {:error, :not_found | :failed}
  def delete(name), do: GenServer.call(__MODULE__, {:delete, name}, 30_000)

  @impl true
  def init(:ok) do
    {:ok, :ok, {:continue, :sweep}}
  end

  @impl true
  def handle_continue(:sweep, state) do
    File.mkdir_p!(Config.repo_root())
    sweep_leftovers()
    {:noreply, state}
  end

  @impl true
  def handle_call({:create, name, owner_uid}, _from, state) do
    {:reply, do_create(name, owner_uid), state}
  end

  def handle_call({:delete, name}, _from, state) do
    {:reply, do_delete(name), state}
  end

  defp do_create(name, owner_uid) do
    root = Config.repo_root()
    target = Repos.dir(name)
    File.mkdir_p!(root)

    if File.exists?(target) do
      {:error, :exists}
    else
      tmp = Path.join(root, @tmp_prefix <> random_suffix())

      with :ok <- File.mkdir_p(tmp),
           {:ok, _} <- Git.run(root, ["init", "--bare", "--quiet", "--initial-branch=main", tmp]),
           {:ok, _} <- Git.run(tmp, ["config", "http.receivepack", "true"]),
           {:ok, _} <- Git.run(tmp, ["config", "pinha.kind", "git"]),
           {:ok, _} <- write_owner(tmp, owner_uid),
           :ok <- File.rm(Path.join(tmp, "description")),
           :ok <- File.rename(tmp, target) do
        {:ok, %Repo{name: name, dir: target, description: nil, owner_uid: owner_uid, kind: :git}}
      else
        error ->
          Logger.error("repo create failed for #{name}: #{inspect(error)}")
          File.rm_rf(tmp)
          {:error, :failed}
      end
    end
  end

  # The owner goes in before the rename, so the repo is never visible without
  # one and a create that dies half way leaves nothing to inherit.
  defp write_owner(_dir, nil), do: {:ok, ""}
  defp write_owner(dir, uid), do: Git.run(dir, ["config", "pinha.owner", uid])

  defp do_delete(name) do
    dir = Repos.dir(name)

    if Repos.bare_repo?(dir) do
      trash = Path.join(Config.repo_root(), @trash_prefix <> random_suffix())

      case File.rename(dir, trash) do
        :ok ->
          remove_async(trash)
          :ok

        {:error, reason} ->
          Logger.error("repo delete failed for #{name}: #{inspect(reason)}")
          {:error, :failed}
      end
    else
      {:error, :not_found}
    end
  end

  defp remove_async(path) do
    Task.Supervisor.start_child(Pinha.TaskSupervisor, fn -> File.rm_rf(path) end)
  end

  # Temporary and trash directories left behind by a crash never appear in the
  # listing (they lack the `.git` suffix), so clearing them at boot is enough.
  defp sweep_leftovers do
    case File.ls(Config.repo_root()) do
      {:ok, entries} ->
        for entry <- entries,
            String.starts_with?(entry, @tmp_prefix) or String.starts_with?(entry, @trash_prefix) do
          remove_async(Path.join(Config.repo_root(), entry))
        end

      {:error, _} ->
        :ok
    end
  end

  defp random_suffix, do: Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
end
