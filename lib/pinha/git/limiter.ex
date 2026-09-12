defmodule Pinha.Git.Limiter do
  @moduledoc """
  A node-wide cap on how many git processes `Pinha.Git.run/3` runs at once.

  Each call holds one slot while its git process runs. Calls past the cap
  wait in arrival order. Holders and waiters are monitored, so a slot comes
  back and a queue entry goes away when the caller exits, however it exits.

  Clone and push transports start git on their own and are not counted.
  """

  use GenServer

  alias Pinha.Config

  @doc false
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Runs `fun` while holding a slot.

  Returns the result together with the milliseconds spent waiting for the
  slot. Without a running limiter, `fun` runs straight away.
  """
  @spec run(GenServer.server(), (-> result)) :: {result, non_neg_integer()} when result: term()
  def run(server \\ __MODULE__, fun) do
    case GenServer.whereis(server) do
      nil ->
        {fun.(), 0}

      pid ->
        started = System.monotonic_time(:millisecond)
        ref = GenServer.call(pid, :acquire, :infinity)
        wait_ms = System.monotonic_time(:millisecond) - started

        try do
          {fun.(), wait_ms}
        after
          GenServer.cast(pid, {:release, ref})
        end
    end
  end

  @impl true
  def init(opts) do
    max = Keyword.get_lazy(opts, :max, &Config.git_max_concurrency/0)
    {:ok, %{max: max, holders: %{}, waiting: :queue.new()}}
  end

  @impl true
  def handle_call(:acquire, {pid, _tag} = from, state) do
    ref = Process.monitor(pid)

    if map_size(state.holders) < state.max do
      {:reply, ref, %{state | holders: Map.put(state.holders, ref, pid)}}
    else
      {:noreply, %{state | waiting: :queue.in({from, ref}, state.waiting)}}
    end
  end

  @impl true
  def handle_cast({:release, ref}, state) do
    Process.demonitor(ref, [:flush])
    {:noreply, release(state, ref)}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    if Map.has_key?(state.holders, ref) do
      {:noreply, release(state, ref)}
    else
      waiting = :queue.filter(fn {_from, waiting_ref} -> waiting_ref != ref end, state.waiting)
      {:noreply, %{state | waiting: waiting}}
    end
  end

  defp release(state, ref) do
    if Map.has_key?(state.holders, ref) do
      grant(%{state | holders: Map.delete(state.holders, ref)})
    else
      state
    end
  end

  defp grant(state) do
    with true <- map_size(state.holders) < state.max,
         {{:value, {{pid, _tag} = from, ref}}, waiting} <- :queue.out(state.waiting) do
      GenServer.reply(from, ref)
      grant(%{state | holders: Map.put(state.holders, ref, pid), waiting: waiting})
    else
      _ -> state
    end
  end
end
