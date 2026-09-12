defmodule Pinha.ParallelTest do
  use ExUnit.Case, async: true

  alias Pinha.Parallel

  test "all/1 returns results in the order the functions were given" do
    assert Parallel.all([fn -> :a end, fn -> :b end, fn -> :c end]) == [:a, :b, :c]
    assert Parallel.all([]) == []
  end

  test "map/3 keeps the input order under bounded concurrency" do
    assert Parallel.map(1..20, &(&1 * 2), max_concurrency: 3) == Enum.map(1..20, &(&1 * 2))
  end

  test "tasks run inside the caller's OpenTelemetry context" do
    OpenTelemetry.Ctx.set_value(:parallel_test, :from_caller)

    assert Parallel.all([fn -> OpenTelemetry.Ctx.get_value(:parallel_test, nil) end]) ==
             [:from_caller]
  end
end
