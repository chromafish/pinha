defmodule Pinha.Git.PktLineTest do
  use ExUnit.Case, async: true

  alias Pinha.Git.PktLine

  test "encode/1 prefixes the payload with its total length in hex" do
    assert PktLine.encode("a\n") == "0006a\n"
    assert PktLine.encode("# service=git-upload-pack\n") == "001e# service=git-upload-pack\n"
    assert PktLine.flush() == "0000"
  end

  test "parse_commands/1 reads ref updates up to the flush packet" do
    old = String.duplicate("0", 40)
    new = String.duplicate("a", 40)

    body =
      PktLine.encode("#{old} #{new} refs/heads/main\0report-status side-band-64k\n") <>
        PktLine.encode("#{new} #{old} refs/tags/v1\n") <>
        PktLine.flush() <> "PACK binary junk"

    assert PktLine.parse_commands(body) == [
             %{old: old, new: new, ref: "refs/heads/main"},
             %{old: new, new: old, ref: "refs/tags/v1"}
           ]
  end

  test "parse_commands/1 tolerates truncated and empty input" do
    assert PktLine.parse_commands("") == []
    assert PktLine.parse_commands("0000") == []
    assert PktLine.parse_commands("00ff short") == []
  end
end
