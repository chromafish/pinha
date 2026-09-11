defmodule PinhaWeb.Helpers do
  @moduledoc "Path building and formatting shared by the templates."

  alias Pinha.Config

  @doc "Path of a repository summary page."
  def repo_path(name), do: "/" <> segment(name)

  @doc "Path of a tree or blob page at a revision."
  def tree_path(name, rev, path \\ "")
  def tree_path(name, rev, ""), do: "/#{segment(name)}/tree/#{segment(rev)}"

  def tree_path(name, rev, path),
    do: "/#{segment(name)}/tree/#{segment(rev)}/#{path_segments(path)}"

  @doc "Path of the raw bytes of a blob."
  def raw_path(name, rev, path),
    do: "/#{segment(name)}/raw/#{segment(rev)}/#{path_segments(path)}"

  @doc "Path of a commit page."
  def commit_path(name, id), do: "/#{segment(name)}/commit/#{segment(id)}"

  @doc "Clone URL built from the configured public base URL."
  def clone_url(name), do: Config.base_url() <> "/" <> segment(name) <> ".git"

  @doc """
  SSH clone URL.

  A listener on 22 is written the short way every git user already knows; any
  other port needs the `ssh://` form, which is the only one that can name one.
  The port is the one the listener actually bound.
  """
  def ssh_clone_url(name) do
    user = Config.ssh_user()
    host = Config.ssh_host()

    case Pinha.Ssh.port() || Config.ssh_port() do
      22 -> "#{user}@#{host}:#{segment(name)}.git"
      port -> "ssh://#{user}@#{host}:#{port}/#{segment(name)}.git"
    end
  end

  @doc "The configured public base URL."
  def base_url, do: Config.base_url()

  @doc """
  Totals for a commit's per-file line counts.

  Binary files report `-` for both sides and count only towards the file
  total, so the numbers shown are always the numbers git reported.
  """
  def stat_totals(stat) do
    Enum.reduce(stat, %{files: 0, added: 0, removed: 0}, fn file, totals ->
      %{
        files: totals.files + 1,
        added: totals.added + count(file.added),
        removed: totals.removed + count(file.removed)
      }
    end)
  end

  defp count(value) do
    case Integer.parse(value) do
      {number, _} -> number
      :error -> 0
    end
  end

  @doc """
  A count with its noun, pluralized: `1 branch`, `2 branches`.

  The number is always shown; only the noun changes.
  """
  def count_label(count, singular, plural \\ nil) do
    plural = plural || singular <> "es"
    "#{count} #{if count == 1, do: singular, else: plural}"
  end

  @doc "`SHA256:...`, the fingerprint form `ssh-keygen` prints."
  def format_fingerprint(fingerprint),
    do: Pinha.Accounts.SshKey.format_fingerprint(fingerprint)

  @doc "Short display form of a commit or change id."
  def short(id), do: Pinha.Git.short(id)

  @doc "`YYYY-MM-DD HH:MM` in the commit's own offset, from git's ISO-8601 output."
  def format_date(nil), do: ""

  def format_date(iso) do
    case String.split(iso, "T") do
      [date, time] -> date <> " " <> String.slice(time, 0, 5)
      _ -> iso
    end
  end

  @doc "Human readable byte size."
  def format_bytes(nil), do: ""
  def format_bytes(bytes) when bytes < 1024, do: "#{bytes} B"
  def format_bytes(bytes) when bytes < 1024 * 1024, do: "#{Float.round(bytes / 1024, 1)} KiB"
  def format_bytes(bytes), do: "#{Float.round(bytes / 1024 / 1024, 1)} MiB"

  @doc "Directory containing `path`, or `nil` at the root."
  def parent_path(""), do: nil

  def parent_path(path) do
    case path |> String.split("/") |> Enum.drop(-1) do
      [] -> ""
      parts -> Enum.join(parts, "/")
    end
  end

  @doc "Cumulative `{name, path}` pairs for a path, for breadcrumb links."
  def breadcrumbs(""), do: []

  def breadcrumbs(path) do
    path
    |> String.split("/", trim: true)
    |> Enum.map_reduce("", fn part, prefix ->
      full = if prefix == "", do: part, else: prefix <> "/" <> part
      {{part, full}, full}
    end)
    |> elem(0)
  end

  @doc "Splits a diff into `{class, text}` lines for colouring."
  def diff_lines(diff) do
    diff
    |> String.split("\n")
    |> Enum.map(fn
      "+++" <> _ = line -> {"diff-file", line}
      "---" <> _ = line -> {"diff-file", line}
      "@@" <> _ = line -> {"diff-hunk", line}
      "diff " <> _ = line -> {"diff-file", line}
      "+" <> _ = line -> {"diff-add", line}
      "-" <> _ = line -> {"diff-del", line}
      line -> {"diff-ctx", line}
    end)
  end

  defp path_segments(path) do
    path
    |> String.split("/", trim: true)
    |> Enum.map_join("/", &segment/1)
  end

  defp segment(value), do: URI.encode(value, &URI.char_unreserved?/1)
end
