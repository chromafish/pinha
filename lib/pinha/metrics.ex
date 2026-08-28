defmodule Pinha.Metrics do
  @moduledoc """
  In-process metric store rendered as Prometheus text at `GET /metrics`.

  Counters and histogram buckets live in public ETS tables so request
  processes update them without a round trip through this process.
  """

  use GenServer

  alias Pinha.Repos

  @counters :pinha_counters
  @histograms :pinha_histograms
  @gauges :pinha_gauges

  @buckets [1, 2, 5, 10, 25, 50, 100, 250, 500, 1000, 2500, 5000, 10_000]

  @help %{
    "http_requests_total" => {"counter", "HTTP requests by route and status."},
    "http_request_duration_ms" => {"histogram", "HTTP request duration in milliseconds."},
    "git_fetches_total" => {"counter", "Clones and fetches served per repository."},
    "git_pushes_total" => {"counter", "Pushes received per repository."},
    "git_ref_updates_total" => {"counter", "Ref updates requested by pushes per repository."},
    "repos_total" => {"gauge", "Repositories in the repo root."},
    "repo_disk_bytes" => {"gauge", "Disk usage per repository, from a cached du."}
  }

  def start_link(opts),
    do: GenServer.start_link(__MODULE__, :ok, Keyword.put_new(opts, :name, __MODULE__))

  @impl true
  def init(:ok) do
    opts = [:named_table, :public, :set, read_concurrency: true, write_concurrency: true]
    :ets.new(@counters, opts)
    :ets.new(@histograms, opts)
    :ets.new(@gauges, opts)
    {:ok, :ok}
  end

  @doc "Adds to a counter series."
  @spec inc(String.t(), [{String.t(), String.t()}], integer()) :: :ok
  def inc(name, labels \\ [], by \\ 1) do
    key = {name, labels}
    :ets.update_counter(@counters, key, by, {key, 0})
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc "Records one observation into a histogram series."
  @spec observe(String.t(), number()) :: :ok
  def observe(name, value) do
    bucket = Enum.find(@buckets, :inf, &(value <= &1))
    bump(@histograms, {name, :bucket, bucket})
    bump(@histograms, {name, :count})
    bump(@histograms, {name, :sum}, round(value))
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc "Sets a gauge series to an absolute value."
  @spec set_gauge(String.t(), [{String.t(), String.t()}], number()) :: :ok
  def set_gauge(name, labels, value) do
    :ets.insert(@gauges, {{name, labels}, value})
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc "Drops every gauge series of `name` whose labels are not in `keep`."
  @spec prune_gauges(String.t(), [[{String.t(), String.t()}]]) :: :ok
  def prune_gauges(name, keep) do
    for {{gauge_name, labels} = key, _value} <- :ets.tab2list(@gauges),
        gauge_name == name and labels not in keep do
      :ets.delete(@gauges, key)
    end

    :ok
  rescue
    ArgumentError -> :ok
  end

  defp bump(table, key, by \\ 1), do: :ets.update_counter(table, key, by, {key, 0})

  @doc "The whole registry in Prometheus text exposition format."
  @spec render() :: iodata()
  def render do
    [counters(), histograms(), gauges()]
  rescue
    ArgumentError -> ""
  end

  defp counters do
    @counters
    |> :ets.tab2list()
    |> Enum.group_by(fn {{name, _labels}, _value} -> name end)
    |> Enum.sort()
    |> Enum.map(fn {name, series} ->
      [
        header(name),
        series
        |> Enum.sort()
        |> Enum.map(fn {{_name, labels}, value} ->
          [name, format_labels(labels), " ", to_string(value), "\n"]
        end)
      ]
    end)
  end

  defp histograms do
    @histograms
    |> :ets.tab2list()
    |> Enum.group_by(fn {key, _value} -> elem(key, 0) end)
    |> Enum.sort()
    |> Enum.map(fn {name, series} ->
      lookup = Map.new(series)
      count = Map.get(lookup, {name, :count}, 0)
      sum = Map.get(lookup, {name, :sum}, 0)

      {lines, _running} =
        Enum.map_reduce(@buckets, 0, fn bucket, running ->
          running = running + Map.get(lookup, {name, :bucket, bucket}, 0)
          {[name, "_bucket{le=\"", to_string(bucket), "\"} ", to_string(running), "\n"], running}
        end)

      [
        header(name),
        lines,
        [name, "_bucket{le=\"+Inf\"} ", to_string(count), "\n"],
        [name, "_sum ", to_string(sum), "\n"],
        [name, "_count ", to_string(count), "\n"]
      ]
    end)
  end

  defp gauges do
    repos = Repos.list()

    live =
      @gauges
      |> :ets.tab2list()
      |> Enum.group_by(fn {{name, _labels}, _value} -> name end)
      |> Enum.sort()
      |> Enum.map(fn {name, series} ->
        [
          header(name),
          series
          |> Enum.sort()
          |> Enum.map(fn {{_name, labels}, value} ->
            [name, format_labels(labels), " ", to_string(value), "\n"]
          end)
        ]
      end)

    [live, header("repos_total"), "repos_total ", to_string(length(repos)), "\n"]
  end

  defp header(name) do
    case Map.fetch(@help, name) do
      {:ok, {type, help}} ->
        ["# HELP ", name, " ", help, "\n# TYPE ", name, " ", type, "\n"]

      :error ->
        []
    end
  end

  defp format_labels([]), do: ""

  defp format_labels(labels) do
    inner =
      labels
      |> Enum.sort()
      |> Enum.map_join(",", fn {key, value} -> [key, "=\"", escape(to_string(value)), "\""] end)

    "{" <> IO.iodata_to_binary(inner) <> "}"
  end

  defp escape(value) do
    value
    |> String.replace("\\", "\\\\")
    |> String.replace("\"", "\\\"")
    |> String.replace("\n", "\\n")
  end
end
