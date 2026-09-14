defmodule Pinha.Git.ChangeIdCache do
  @moduledoc """
  Jujutsu change IDs already read from commit objects on this node.

  A commit object never changes, so a change ID read from one stays correct
  and entries are never invalidated. Keys pair the repository directory with
  the commit id. Native `change-id` headers and legacy `change-id` trailers
  are kept apart, since log output carries trailers already and only the
  header needs a separate read. A nil value records a commit read without
  one, so it is not read again either.

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

  @doc "Records the native header read for each commit id: its change ID, or nil."
  @spec put(String.t(), %{String.t() => String.t() | nil}) :: :ok
  def put(dir, change_ids) do
    insert(Enum.map(change_ids, fn {id, change_id} -> {{dir, id}, change_id} end))
  end

  @doc "The trailer change ID already read for one commit, nil included."
  @spec lookup_trailer(String.t(), String.t()) :: {:ok, String.t() | nil} | :error
  def lookup_trailer(dir, id) do
    with true <- table?(),
         [{_key, change_id}] <- :ets.lookup(__MODULE__, {dir, id, :trailer}) do
      {:ok, change_id}
    else
      _ -> :error
    end
  end

  @doc "Records the trailer change ID read for one commit, or nil."
  @spec put_trailer(String.t(), String.t(), String.t() | nil) :: :ok
  def put_trailer(dir, id, change_id), do: insert([{{dir, id, :trailer}, change_id}])

  defp insert([]), do: :ok

  defp insert(entries) do
    if table?() do
      if :ets.info(__MODULE__, :size) + length(entries) > Config.change_id_cache_max_entries() do
        :ets.delete_all_objects(__MODULE__)
      end

      :ets.insert(__MODULE__, entries)
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
