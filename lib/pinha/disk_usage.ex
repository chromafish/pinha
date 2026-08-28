defmodule Pinha.DiskUsage do
  @moduledoc """
  Refreshes the cached `du` output behind `repo_disk_bytes` roughly every 60
  seconds, so scraping `/metrics` never walks the repo root itself.
  """

  use GenServer

  alias Pinha.Config
  alias Pinha.Metrics
  alias Pinha.Repos

  def start_link(opts),
    do: GenServer.start_link(__MODULE__, :ok, Keyword.put_new(opts, :name, __MODULE__))

  @doc "Measures every repo now, synchronously."
  @spec refresh() :: :ok
  def refresh do
    repos = Repos.list()

    for repo <- repos do
      case measure(repo.dir) do
        {:ok, bytes} -> Metrics.set_gauge("repo_disk_bytes", [{"repo", repo.name}], bytes)
        :error -> :ok
      end
    end

    Metrics.prune_gauges("repo_disk_bytes", Enum.map(repos, &[{"repo", &1.name}]))
    :ok
  end

  @impl true
  def init(:ok) do
    schedule(0)
    {:ok, :ok}
  end

  @impl true
  def handle_info(:refresh, state) do
    refresh()
    schedule(Config.disk_usage_interval_ms())
    {:noreply, state}
  end

  defp schedule(after_ms), do: Process.send_after(self(), :refresh, after_ms)

  defp measure(dir) do
    case System.cmd("du", ["-sk", dir], stderr_to_stdout: false) do
      {out, 0} ->
        case Integer.parse(String.trim_leading(out)) do
          {kb, _rest} -> {:ok, kb * 1024}
          :error -> :error
        end

      _ ->
        :error
    end
  rescue
    ErlangError -> :error
  end
end
