defmodule Pinha.Accounts.SessionCache do
  @moduledoc """
  The short-lived, node-local view of live browser sessions.

  Reads go straight to ETS, so a warm session does not queue behind a process
  or cross the network to Postgres. The owning GenServer serializes the much
  rarer writes, invalidations, and expiry sweeps. Postgres remains the source
  of truth: a miss revalidates there, and cached answers live only for the
  configured TTL.

  Entries are keyed by the token's SHA-256, never the raw cookie value.
  """

  use GenServer

  alias Pinha.Accounts.User

  @cache_event [:pinha, :accounts, :session_cache]
  @generation_key :generation

  @type generation :: non_neg_integer()

  @doc false
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Returns a cached user, or the generation a database fill must match."
  @spec fetch(binary()) :: {:ok, User.t()} | {:miss, generation()}
  def fetch(token_hash) when is_binary(token_hash) do
    now_ms = System.monotonic_time(:millisecond)

    case :ets.lookup(__MODULE__, token_hash) do
      [{^token_hash, _user_id, expires_at_ms, user}] when expires_at_ms > now_ms ->
        emit(:hit)
        {:ok, user}

      _ ->
        emit(:miss)
        {:miss, generation()}
    end
  end

  @doc "Seeds or refreshes a successful session lookup."
  @spec put(binary(), User.t(), keyword()) :: :ok
  def put(token_hash, %User{} = user, opts \\ []) when is_binary(token_hash) do
    ttl_ms = Keyword.get(opts, :ttl_ms)

    if not is_nil(ttl_ms) and (not is_integer(ttl_ms) or ttl_ms < 0) do
      raise ArgumentError, ":ttl_ms must be a non-negative integer"
    end

    GenServer.call(__MODULE__, {:put, token_hash, user, ttl_ms})
  end

  @doc "Stores a database result unless an invalidation happened while it loaded."
  @spec put_if_fresh(binary(), User.t(), generation()) :: :ok | :stale
  def put_if_fresh(token_hash, %User{} = user, generation)
      when is_binary(token_hash) and is_integer(generation) and generation >= 0 do
    GenServer.call(__MODULE__, {:put_if_fresh, token_hash, user, generation})
  end

  @doc "Removes one cached session."
  @spec evict(binary()) :: :ok
  def evict(token_hash) when is_binary(token_hash) do
    GenServer.call(__MODULE__, {:evict, token_hash})
  end

  @doc "Removes every cached session carrying this user."
  @spec evict_user(integer()) :: :ok
  def evict_user(user_id) when is_integer(user_id) do
    GenServer.call(__MODULE__, {:evict_user, user_id})
  end

  @doc false
  @spec clear() :: :ok
  def clear do
    GenServer.call(__MODULE__, :clear)
  end

  @doc false
  @spec size() :: non_neg_integer()
  def size do
    max(:ets.info(__MODULE__, :size) - 1, 0)
  end

  @impl true
  def init(opts) do
    ttl_ms = Keyword.get(opts, :ttl_ms, Application.fetch_env!(:pinha, :session_cache_ttl_ms))

    sweep_interval_ms =
      Keyword.get(
        opts,
        :sweep_interval_ms,
        Application.fetch_env!(:pinha, :session_cache_sweep_interval_ms)
      )

    :ets.new(__MODULE__, [
      :named_table,
      :set,
      :protected,
      read_concurrency: true,
      write_concurrency: true
    ])

    :ets.insert(__MODULE__, {@generation_key, 0})
    schedule_sweep(sweep_interval_ms)

    {:ok, %{generation: 0, ttl_ms: ttl_ms, sweep_interval_ms: sweep_interval_ms}}
  end

  @impl true
  def handle_call({:put, token_hash, user, ttl_ms}, _from, state) do
    insert(token_hash, user, ttl_ms || state.ttl_ms)
    {:reply, :ok, state}
  end

  def handle_call({:put_if_fresh, token_hash, user, generation}, _from, state) do
    if generation == state.generation do
      insert(token_hash, user, state.ttl_ms)
      {:reply, :ok, state}
    else
      {:reply, :stale, state}
    end
  end

  def handle_call({:evict, token_hash}, _from, state) do
    state = bump_generation(state)
    :ets.delete(__MODULE__, token_hash)
    {:reply, :ok, state}
  end

  def handle_call({:evict_user, user_id}, _from, state) do
    state = bump_generation(state)

    :ets.select_delete(__MODULE__, [
      {{:"$1", user_id, :"$2", :"$3"}, [], [true]}
    ])

    {:reply, :ok, state}
  end

  def handle_call(:clear, _from, state) do
    generation = state.generation + 1
    :ets.delete_all_objects(__MODULE__)
    :ets.insert(__MODULE__, {@generation_key, generation})
    {:reply, :ok, %{state | generation: generation}}
  end

  @impl true
  def handle_info(:sweep, state) do
    now_ms = System.monotonic_time(:millisecond)

    :ets.select_delete(__MODULE__, [
      {{:"$1", :"$2", :"$3", :"$4"}, [{:"=<", :"$3", now_ms}], [true]}
    ])

    schedule_sweep(state.sweep_interval_ms)
    {:noreply, state}
  end

  defp insert(token_hash, user, ttl_ms) do
    expires_at_ms = System.monotonic_time(:millisecond) + ttl_ms
    :ets.insert(__MODULE__, {token_hash, user.id, expires_at_ms, user})
  end

  defp generation do
    :ets.lookup_element(__MODULE__, @generation_key, 2)
  end

  defp bump_generation(state) do
    generation = state.generation + 1
    :ets.insert(__MODULE__, {@generation_key, generation})
    %{state | generation: generation}
  end

  defp schedule_sweep(interval_ms) do
    Process.send_after(self(), :sweep, interval_ms)
  end

  defp emit(result) do
    :telemetry.execute(@cache_event, %{count: 1}, %{result: result})
  end
end
