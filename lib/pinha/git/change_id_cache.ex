defmodule Pinha.Git.ChangeIdCache do
  @moduledoc """
  Native Jujutsu change IDs already read from commit objects on this node.

  A commit object never changes, so a change ID read from one stays correct
  and entries are never invalidated. Keys pair the repository directory with
  the commit id. A nil value records a commit without a native header, so it
  is not read again either.

  Reads and writes go straight to a public ETS table. When a write would take
  the table past `Pinha.Config.change_id_cache_max_entries/0`, the table is
  emptied first. Without the table, lookups miss and writes are dropped.
  """

  use GenServer

  alias Pinha.Config

  @doc false
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Splits `ids` into the change IDs already known and the ids still to read."
  @spec lookup(String.t(), [String.t()]) :: {%{String.t() => String.t() | nil}, [String.t()]}
  def lookup(dir, ids) do
    if table?() do
      {found, unread} =
        Enum.reduce(ids, {%{}, []}, fn id, {found, unread} ->
          case :ets.lookup(__MODULE__, {dir, id}) do
            [{_key, change_id}] -> {Map.put(found, id, change_id), unread}
            [] -> {found, [id | unread]}
          end
        end)

      {found, Enum.reverse(unread)}
    else
      {%{}, ids}
    end
  end

  @doc "Records what was read for each commit id: its change ID, or nil."
  @spec put(String.t(), %{String.t() => String.t() | nil}) :: :ok
  def put(dir, change_ids) do
    if table?() and map_size(change_ids) > 0 do
      if :ets.info(__MODULE__, :size) + map_size(change_ids) >
           Config.change_id_cache_max_entries() do
        :ets.delete_all_objects(__MODULE__)
      end

      :ets.insert(
        __MODULE__,
        Enum.map(change_ids, fn {id, change_id} -> {{dir, id}, change_id} end)
      )
    end

    :ok
  end

  @doc false
  @spec size() :: non_neg_integer()
  def size, do: if(table?(), do: :ets.info(__MODULE__, :size), else: 0)

  defp table?, do: :ets.whereis(__MODULE__) != :undefined

  @impl true
  def init(_opts) do
    :ets.new(__MODULE__, [
      :named_table,
      :set,
      :public,
      read_concurrency: true,
      write_concurrency: true
    ])

    {:ok, nil}
  end
end
