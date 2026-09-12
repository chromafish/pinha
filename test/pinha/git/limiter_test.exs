defmodule Pinha.Git.LimiterTest do
  use ExUnit.Case, async: true

  alias Pinha.Git.Limiter

  setup do
    name = :"limiter_#{System.unique_integer([:positive])}"
    start_supervised!({Limiter, name: name, max: 1})
    [limiter: name]
  end

  test "a call past the cap waits for a slot", %{limiter: limiter} do
    test = self()
    holder = Task.async(fn -> Limiter.run(limiter, fn -> hold(test) end) end)
    assert_receive :holding

    waiter = Task.async(fn -> Limiter.run(limiter, fn -> send(test, :ran) && :waited end) end)
    refute_receive :ran, 100

    send(holder.pid, :release)
    assert {:held, _} = Task.await(holder)
    assert_receive :ran
    assert {:waited, wait_ms} = Task.await(waiter)
    assert wait_ms >= 100
  end

  test "a holder that exits gives its slot back", %{limiter: limiter} do
    test = self()
    {pid, monitor} = spawn_monitor(fn -> Limiter.run(limiter, fn -> hold(test) end) end)
    assert_receive :holding

    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :killed}
    assert {:ok, _} = Limiter.run(limiter, fn -> :ok end)
  end

  test "a waiter that exits leaves the queue", %{limiter: limiter} do
    test = self()
    holder = Task.async(fn -> Limiter.run(limiter, fn -> hold(test) end) end)
    assert_receive :holding

    {pid, monitor} =
      spawn_monitor(fn -> Limiter.run(limiter, fn -> send(test, :waiter_ran) end) end)

    refute_receive :waiter_ran, 50
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :killed}

    send(holder.pid, :release)
    assert {:held, _} = Task.await(holder)
    assert {:ok, _} = Limiter.run(limiter, fn -> :ok end)
    refute_received :waiter_ran
  end

  test "without a running limiter the function runs straight away" do
    assert Limiter.run(:no_such_limiter, fn -> :ok end) == {:ok, 0}
  end

  defp hold(test) do
    send(test, :holding)

    receive do
      :release -> :held
    end
  end
end
