defmodule Pinha.Parallel do
  @moduledoc """
  Runs independent work concurrently, inside the caller's trace.

  A `Task` process starts with an empty OpenTelemetry context, so a span it
  starts would begin a trace of its own. Every function here attaches the
  caller's context in the task first, which keeps git and query spans under
  the request that caused them.

  Tasks are started with `Task.async_stream/3`, so they are linked to the
  caller and carry `$callers` for Ecto sandbox access in tests. There is no
  timeout: a slow git read waits as long as it would have run inline.
  """

  @doc "Runs each function concurrently and returns their results in order."
  @spec all([(-> term())]) :: [term()]
  def all(funs) when is_list(funs) do
    map(funs, & &1.(), max_concurrency: max(length(funs), 1))
  end

  @doc """
  Maps `fun` over `enumerable` concurrently, keeping the input order.

  `:max_concurrency` defaults to the number of online schedulers.
  """
  @spec map(Enumerable.t(), (term() -> term()), keyword()) :: [term()]
  def map(enumerable, fun, opts \\ []) do
    ctx = OpenTelemetry.Ctx.get_current()

    enumerable
    |> Task.async_stream(
      fn item ->
        OpenTelemetry.Ctx.attach(ctx)
        fun.(item)
      end,
      max_concurrency: Keyword.get(opts, :max_concurrency, System.schedulers_online()),
      ordered: true,
      timeout: :infinity
    )
    |> Enum.map(fn {:ok, result} -> result end)
  end
end
