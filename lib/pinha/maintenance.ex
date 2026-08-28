defmodule Pinha.Maintenance do
  @moduledoc """
  Repository upkeep in supervised background processes.

  A task after each receive runs `git gc --auto`; a periodic job prunes and
  repacks every repo without blocking push responses.
  """

  use GenServer

  alias Pinha.Config
  alias Pinha.Git
  alias Pinha.Repos

  require Logger

  def start_link(opts),
    do: GenServer.start_link(__MODULE__, :ok, Keyword.put_new(opts, :name, __MODULE__))

  @doc "Runs `git gc --auto` for a repo off the request process."
  @spec after_receive(Repos.Repo.t()) :: :ok
  def after_receive(repo) do
    Task.Supervisor.start_child(Pinha.TaskSupervisor, fn -> gc_auto(repo) end)
    :ok
  end

  @doc "Prunes and repacks every repository, one at a time."
  @spec run_all() :: :ok
  def run_all do
    for repo <- Repos.list(), do: gc(repo)
    :ok
  end

  @impl true
  def init(:ok) do
    schedule()
    {:ok, :ok}
  end

  @impl true
  def handle_info(:maintain, state) do
    run_all()
    schedule()
    {:noreply, state}
  end

  defp schedule, do: Process.send_after(self(), :maintain, Config.maintenance_interval_ms())

  defp gc_auto(repo) do
    case Git.run(repo.dir, ["gc", "--auto", "--quiet"]) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.warning("git gc --auto failed for #{repo.name}: #{inspect(reason)}")
    end
  end

  defp gc(repo) do
    case Git.run(repo.dir, ["gc", "--quiet"]) do
      {:ok, _} -> :ok
      {:error, reason} -> Logger.warning("git gc failed for #{repo.name}: #{inspect(reason)}")
    end
  end
end
