defmodule Pinha.Ssh.Command do
  @moduledoc """
  What an SSH session is allowed to ask for.

  git turns `git@host:name.git` into an exec request carrying one command
  string, which is parsed here without a shell: the words are split the way a
  shell would split them, and then matched against exactly two verbs and one
  repository name. Nothing else runs, so the command string can never become
  execution.
  """

  alias Pinha.Repos

  @verbs %{
    "git-upload-pack" => "upload-pack",
    "git-receive-pack" => "receive-pack"
  }

  @doc """
  Parses an exec command into `{subcommand, repository name}`.

  `git-upload-archive` and every other verb are refused, as is a path naming
  anything but one repository directly under the repo root.
  """
  @spec parse(binary() | charlist()) ::
          {:ok, String.t(), String.t()} | {:error, :unsupported | :invalid_name}
  def parse(command) do
    case words(to_string(command)) do
      [verb, path] ->
        case Map.fetch(@verbs, verb) do
          {:ok, subcommand} -> with {:ok, name} <- repo_name(path), do: {:ok, subcommand, name}
          :error -> {:error, :unsupported}
        end

      _ ->
        {:error, :unsupported}
    end
  end

  # `ssh://git@host/name.git` arrives as `/name.git` and `git@host:name.git`
  # as `name.git`; `~/name.git` is the same repo written the way scp would.
  # Everything after that is the name rule an HTTP `:repo` segment gets.
  defp repo_name(path) do
    path
    |> String.trim_leading("~")
    |> String.trim_leading("/")
    |> Repos.normalize_name()
  end

  @doc """
  Splits a command string into words the way a POSIX shell would.

  git quotes the repository path, so the quoting has to be understood, but
  nothing here expands, globs, or substitutes: an unterminated quote is a
  malformed command rather than a prompt for more.
  """
  @spec words(String.t()) :: [String.t()] | :error
  def words(command), do: split(command, [], [], nil)

  defp split(<<>>, word, words, nil), do: Enum.reverse(finish(word, words))
  defp split(<<>>, _word, _words, _quote), do: :error

  defp split(<<?\\, char, rest::binary>>, word, words, nil),
    do: split(rest, [char | word], words, nil)

  defp split(<<?\\, char, rest::binary>>, word, words, ?") when char in [?", ?\\, ?$, ?`],
    do: split(rest, [char | word], words, ?")

  defp split(<<char, rest::binary>>, word, words, nil) when char in [?', ?"],
    do: split(rest, word, words, char)

  defp split(<<char, rest::binary>>, word, words, char),
    do: split(rest, word, words, nil)

  defp split(<<char, rest::binary>>, word, words, nil) when char in [?\s, ?\t] do
    case word do
      [] -> split(rest, [], words, nil)
      _ -> split(rest, [], finish(word, words), nil)
    end
  end

  defp split(<<char, rest::binary>>, word, words, quote_char),
    do: split(rest, [char | word], words, quote_char)

  defp finish([], words), do: words
  defp finish(word, words), do: [word |> Enum.reverse() |> List.to_string() | words]
end
