defmodule Pinha.Git.PktLine do
  @moduledoc "Encoding and parsing for git's pkt-line framing."

  @doc "Wraps a payload in a length-prefixed pkt-line."
  @spec encode(binary()) :: binary()
  def encode(data) do
    size = byte_size(data) + 4
    (size |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(4, "0")) <> data
  end

  @doc "The flush packet that ends a section."
  @spec flush() :: binary()
  def flush, do: "0000"

  @doc """
  Parses the ref update commands at the head of a receive-pack request.

  Each command is `<old-id> <new-id> <ref>`, optionally followed by a NUL and
  the client capabilities. Parsing stops at the flush packet that precedes the
  pack data.
  """
  @spec parse_commands(binary()) :: [%{old: String.t(), new: String.t(), ref: String.t()}]
  def parse_commands(binary), do: binary |> packets() |> Enum.flat_map(&parse_command/1)

  defp parse_command(payload) do
    payload
    |> String.split(<<0>>, parts: 2)
    |> hd()
    |> String.trim()
    |> String.split(" ", parts: 3)
    |> case do
      [old, new, ref] -> [%{old: old, new: new, ref: ref}]
      _ -> []
    end
  end

  @doc "Splits a pkt-line stream into payloads, stopping at the first flush."
  @spec packets(binary()) :: [binary()]
  def packets(binary), do: packets(binary, [])

  defp packets(<<length::binary-size(4), rest::binary>>, acc) do
    case Integer.parse(length, 16) do
      {0, ""} ->
        Enum.reverse(acc)

      {size, ""} when size >= 4 ->
        payload_size = size - 4

        case rest do
          <<payload::binary-size(payload_size), tail::binary>> ->
            packets(tail, [payload | acc])

          _ ->
            Enum.reverse(acc)
        end

      _ ->
        Enum.reverse(acc)
    end
  end

  defp packets(_, acc), do: Enum.reverse(acc)
end
