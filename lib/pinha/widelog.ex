defmodule Pinha.Widelog do
  @moduledoc """
  One canonical line per request, on stdout, as JSON.

  Both transports write the same shape: what was asked for, of which repo, by
  whom, how it ended, how long it took, and how many bytes moved. An HTTP
  request fills in method, route, and user agent; an SSH session fills in the
  git exit status instead, and carries `transport` to say which is which.
  """

  alias Pinha.Config

  @doc "Writes one line, unless widelogs are switched off."
  @spec write(map()) :: :ok
  def write(fields) do
    if Config.widelog?() do
      IO.puts(Jason.encode_to_iodata!(Map.put_new_lazy(fields, :ts, &timestamp/0)))
    end

    :ok
  end

  @doc """
  Trims a push's ref updates to what a log line should carry.

  A push of a thousand branches is still one line, so the refs are truncated
  and the total is kept next to them.
  """
  @spec put_refs(map(), [map()] | nil) :: map()
  def put_refs(line, nil), do: line

  def put_refs(line, refs) do
    max = Config.log_max_refs()
    shown = Enum.take(refs, max)

    line
    |> Map.put(:refs, Enum.map(shown, &%{ref: &1.ref, old: &1.old, new: &1.new}))
    |> Map.put(:refs_total, length(refs))
    |> Map.put(:refs_truncated, max(length(refs) - length(shown), 0))
  end

  defp timestamp, do: DateTime.utc_now() |> DateTime.to_iso8601()
end
