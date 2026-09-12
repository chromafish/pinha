defmodule Pinha.Git do
  @moduledoc """
  Reads bare repositories by shelling out to `git`.

  Git is the source of truth: there is no metadata store and no index, so
  every call here runs against the repo on disk. The server never runs `jj`;
  Jujutsu support comes from reading the `change-id` trailer that clients
  write into their commits.
  """

  alias Pinha.Config
  alias Pinha.Repos.Repo
  alias Pinha.Widelog

  require OpenTelemetry.Tracer, as: Tracer

  @us <<0x1F>>
  @rs <<0x1E>>
  @cid <<0x1D>>

  @commit_format "%H%x1f%P%x1f%an%x1f%ae%x1f%aI%x1f%cn%x1f%ce%x1f%cI%x1f" <>
                   "%(trailers:key=change-id,valueonly,separator=%x1d)%x1f%s%x1f%b%x1e"

  @max_render_bytes 5_000_000

  @stderr_var "PINHA_STDERR"
  @stderr_limit 4_000

  @type commit :: %{
          id: String.t(),
          parents: [String.t()],
          author_name: String.t(),
          author_email: String.t(),
          author_date: String.t(),
          committer_name: String.t(),
          committer_email: String.t(),
          committer_date: String.t(),
          change_id: String.t() | nil,
          subject: String.t(),
          body: String.t()
        }

  @doc """
  Runs git in `dir` and returns stdout.

  git's stderr is captured rather than inherited: a failure becomes one
  widelog line carrying the repository, the arguments, the exit status, and
  what git said, instead of unstructured text next to the request lines.
  """
  @spec run(String.t(), [String.t()], keyword()) :: {:ok, binary()} | {:error, {:exit, integer()}}
  def run(dir, args, opts \\ []) do
    subcommand = List.first(args) || "git"
    args = ["-c", "core.quotePath=false" | args]
    stderr = stderr_path()

    Tracer.with_span "git #{subcommand}", %{attributes: span_attributes(dir, subcommand, args)} do
      try do
        case System.cmd("/bin/sh", shell_args(Config.git_bin(), args),
               cd: dir,
               env: [{@stderr_var, stderr} | env(opts)],
               stderr_to_stdout: false
             ) do
          {out, 0} ->
            {:ok, out}

          {_out, code} ->
            message = read_stderr(stderr)
            log_failure(dir, args, code, message)
            record_failure(code, message)
            {:error, {:exit, code}}
        end
      after
        File.rm(stderr)
      end
    end
  end

  @doc "The attributes every git span carries, whatever started it."
  @spec span_attributes(String.t(), String.t(), [String.t()]) :: [{String.t(), term()}]
  def span_attributes(dir, subcommand, args) do
    [
      {"git.subcommand", subcommand},
      {"git.argv", Enum.map_join(args, " ", &scrub/1)},
      {"repo", Path.basename(dir, ".git")}
    ]
  end

  @doc "Marks the current span as a git failure, with what git said."
  @spec record_failure(integer(), String.t() | nil) :: :ok
  def record_failure(status, stderr) do
    Tracer.set_attributes([{"git.status", status}, {"git.stderr", stderr || ""}, {"error", true}])
    Tracer.set_status(OpenTelemetry.status(:error, "git exited #{status}"))
    :ok
  end

  @doc """
  Arguments that run `bin` under `/bin/sh` with its stderr redirected.

  The command is a fixed string and every argument arrives as a positional
  parameter, so nothing a client sends is ever parsed by the shell. The
  redirect target comes from the environment for the same reason.
  """
  @spec shell_args(String.t(), [String.t()]) :: [String.t()]
  def shell_args(bin, args), do: ["-c", ~s(exec "$@" 2>"$#{@stderr_var}"), "sh", bin | args]

  @doc "A path for one invocation's stderr, removed by whoever created it."
  @spec stderr_path() :: String.t()
  def stderr_path do
    Path.join(
      System.tmp_dir!(),
      "pinha-stderr-" <> Base.encode16(:crypto.strong_rand_bytes(12), case: :lower)
    )
  end

  @doc "The name of the environment variable naming that path."
  @spec stderr_var() :: String.t()
  def stderr_var, do: @stderr_var

  @doc "Reads captured stderr, trimmed and truncated to something a log line can hold."
  @spec read_stderr(String.t()) :: String.t() | nil
  def read_stderr(path) do
    case File.read(path) do
      {:ok, ""} ->
        nil

      {:ok, text} ->
        text = text |> scrub() |> String.trim()

        cond do
          text == "" -> nil
          byte_size(text) > @stderr_limit -> binary_part(text, 0, @stderr_limit) <> "…"
          true -> text
        end

      {:error, _} ->
        nil
    end
  end

  @doc "One widelog line for a git invocation that failed on its own."
  @spec log_failure(String.t(), [String.t()], integer(), String.t() | nil) :: :ok
  def log_failure(dir, args, status, stderr) do
    Widelog.write(%{
      event: "git",
      repo: Path.basename(dir, ".git"),
      argv: Enum.map(args, &scrub/1),
      status: status,
      stderr: stderr
    })
  end

  @doc "Environment every git invocation runs under: no system or user config."
  @spec env(keyword()) :: [{String.t(), String.t()}]
  def env(opts \\ []) do
    [
      {"GIT_CONFIG_NOSYSTEM", "1"},
      {"GIT_CONFIG_GLOBAL", "/dev/null"},
      {"GIT_ATTR_NOSYSTEM", "1"},
      {"GIT_TERMINAL_PROMPT", "0"}
    ] ++ Keyword.get(opts, :env, [])
  end

  @doc "Short name of the branch `HEAD` points at, or nil when HEAD is detached."
  @spec default_branch(Repo.t()) :: String.t() | nil
  def default_branch(%Repo{dir: dir}) do
    case run(dir, ["symbolic-ref", "--short", "HEAD"]) do
      {:ok, out} -> String.trim(out)
      {:error, _} -> nil
    end
  end

  @doc "Branches with their tip commit id, tip date, and subject."
  @spec branches(Repo.t()) :: [map()]
  def branches(repo), do: refs(repo, "refs/heads")

  @doc "Tags with the tag object and, for annotated tags, the commit it peels to."
  @spec tags(Repo.t()) :: [map()]
  def tags(repo), do: refs(repo, "refs/tags")

  defp refs(%Repo{dir: dir}, namespace) do
    format =
      "%(refname:short)#{@us}%(objectname)#{@us}%(*objectname)#{@us}" <>
        "%(committerdate:iso-strict)#{@us}%(contents:subject)"

    case run(dir, ["for-each-ref", "--format=" <> format, namespace]) do
      {:ok, out} ->
        out
        |> String.split("\n", trim: true)
        |> Enum.map(fn line ->
          [name, oid, peeled, date, subject] =
            (String.split(line, @us) ++ ["", "", "", "", ""]) |> Enum.take(5)

          %{
            name: scrub(name),
            id: if(peeled != "", do: peeled, else: oid),
            ref_id: oid,
            date: date,
            subject: scrub(subject)
          }
        end)

      {:error, _} ->
        []
    end
  end

  @doc """
  Resolves a `:rev` from the URL.

  Full commit id first, then branch, then tag, then Jujutsu change id (full or
  unique prefix). Short commit ids are not resolved. An ambiguous change-id
  prefix, or a change id shared by divergent commits, returns every match.
  """
  @spec resolve(Repo.t(), String.t()) ::
          {:ok, map()} | {:ambiguous, [map()]} | {:error, :not_found}
  def resolve(repo, rev) when is_binary(rev) do
    with :error <- resolve_commit_id(repo, rev),
         :error <- resolve_branch(repo, rev),
         :error <- resolve_tag(repo, rev) do
      resolve_change_id(repo, rev)
    end
  end

  defp resolve_commit_id(%Repo{dir: dir} = repo, rev) do
    if full_object_id?(rev) do
      case run(dir, ["rev-parse", "--verify", "--quiet", "--end-of-options", rev <> "^{commit}"]) do
        {:ok, out} ->
          id = String.trim(out)
          {:ok, %{id: id, kind: :commit, name: rev, change_id: change_id_of(repo, id)}}

        {:error, _} ->
          :error
      end
    else
      :error
    end
  end

  defp resolve_branch(repo, rev) do
    case Enum.find(branches(repo), &(&1.name == rev)) do
      nil ->
        :error

      branch ->
        {:ok,
         %{id: branch.id, kind: :branch, name: rev, change_id: change_id_of(repo, branch.id)}}
    end
  end

  defp resolve_tag(repo, rev) do
    case Enum.find(tags(repo), &(&1.name == rev)) do
      nil -> :error
      tag -> {:ok, %{id: tag.id, kind: :tag, name: rev, change_id: change_id_of(repo, tag.id)}}
    end
  end

  defp resolve_change_id(repo, rev) do
    if change_id_prefix?(rev) do
      case change_id_matches(repo, rev) do
        [] -> {:error, :not_found}
        [one] -> {:ok, %{id: one.id, kind: :change_id, name: rev, change_id: one.change_id}}
        many -> {:ambiguous, many}
      end
    else
      {:error, :not_found}
    end
  end

  @doc """
  Every commit whose `change-id` trailer starts with `prefix`.

  Divergent commits sharing one change id each appear on their own; there is
  no grouping in v0.1.
  """
  @spec change_id_matches(Repo.t(), String.t()) :: [map()]
  def change_id_matches(%Repo{dir: dir}, prefix) do
    prefix = String.downcase(prefix)

    case run(dir, [
           "log",
           "--all",
           "--no-color",
           "--format=%H#{@us}%(trailers:key=change-id,valueonly,separator=#{@cid})#{@us}%s"
         ]) do
      {:ok, out} ->
        out
        |> String.split("\n", trim: true)
        |> Enum.flat_map(fn line ->
          case String.split(line, @us) do
            [id, change_ids, subject] ->
              change_ids
              |> String.split(@cid, trim: true)
              |> Enum.map(&String.trim/1)
              |> Enum.filter(&String.starts_with?(String.downcase(&1), prefix))
              |> Enum.map(&%{id: id, change_id: &1, subject: scrub(subject)})

            _ ->
              []
          end
        end)
        |> Enum.uniq_by(& &1.id)

      {:error, _} ->
        []
    end
  end

  @doc "The `change-id` trailer of one commit, when the client wrote one."
  @spec change_id_of(Repo.t(), String.t()) :: String.t() | nil
  def change_id_of(%Repo{dir: dir}, id) do
    case run(dir, [
           "show",
           "--no-patch",
           "--format=%(trailers:key=change-id,valueonly,separator=#{@cid})",
           id
         ]) do
      {:ok, out} ->
        case out
             |> String.split(@cid, trim: true)
             |> Enum.map(&String.trim/1)
             |> Enum.reject(&(&1 == "")) do
          [] -> nil
          [first | _] -> first
        end

      {:error, _} ->
        nil
    end
  end

  @doc "Recent commits reachable from `rev`, newest first."
  @spec log(Repo.t(), String.t(), keyword()) :: [commit()]
  def log(%Repo{dir: dir}, rev, opts \\ []) do
    limit = Keyword.get(opts, :limit, 20)
    skip = Keyword.get(opts, :skip, 0)

    args =
      [
        "log",
        "--no-color",
        "--max-count=#{limit}",
        "--skip=#{skip}",
        "--format=" <> @commit_format
      ] ++
        [rev] ++ path_args(Keyword.get(opts, :path))

    case run(dir, args) do
      {:ok, out} -> parse_commits(out)
      {:error, _} -> []
    end
  end

  defp path_args(nil), do: []
  defp path_args(""), do: []
  defp path_args(path), do: ["--", path]

  @doc "One commit's metadata, parents, and `change-id` trailer."
  @spec commit(Repo.t(), String.t()) :: {:ok, commit()} | {:error, :not_found}
  def commit(%Repo{dir: dir}, id) do
    case run(dir, ["show", "--no-patch", "--no-color", "--format=" <> @commit_format, id]) do
      {:ok, out} ->
        case parse_commits(out) do
          [commit] -> {:ok, commit}
          _ -> {:error, :not_found}
        end

      {:error, _} ->
        {:error, :not_found}
    end
  end

  @doc "Full patch for a commit, combined-diff style for merges."
  @spec diff(Repo.t(), String.t()) :: String.t()
  def diff(%Repo{dir: dir}, id) do
    args = ["diff-tree", "--no-commit-id", "--no-color", "--root", "--cc", "-M", "-p", id]

    case run(dir, args) do
      {:ok, out} -> scrub(out)
      {:error, _} -> ""
    end
  end

  @doc "Per-file added/removed line counts for a commit."
  @spec diff_stat(Repo.t(), String.t()) :: [map()]
  def diff_stat(%Repo{dir: dir}, id) do
    case run(dir, ["diff-tree", "--no-commit-id", "--numstat", "--root", "-M", id]) do
      {:ok, out} ->
        out
        |> String.split("\n", trim: true)
        |> Enum.flat_map(fn line ->
          case String.split(line, "\t") do
            [added, removed, path] ->
              [%{added: added, removed: removed, path: scrub(path)}]

            _ ->
              []
          end
        end)

      {:error, _} ->
        []
    end
  end

  @doc "Object type at `path` in the commit, or `:error` when it does not exist."
  @spec object_type(Repo.t(), String.t(), String.t()) :: {:ok, String.t()} | :error
  def object_type(%Repo{dir: dir}, id, path) do
    case run(dir, ["cat-file", "-t", spec(id, path)]) do
      {:ok, out} -> {:ok, String.trim(out)}
      {:error, _} -> :error
    end
  end

  @doc "Directory entries at `path`, sorted with directories first."
  @spec list_tree(Repo.t(), String.t(), String.t()) :: {:ok, [map()]} | {:error, :not_found}
  def list_tree(%Repo{dir: dir}, id, path) do
    prefix = if path == "", do: "", else: path <> "/"

    case run(dir, ["ls-tree", "--long", "-z", spec(id, path) <> if(path == "", do: "", else: "/")]) do
      {:ok, out} ->
        entries =
          out
          |> String.split(<<0>>, trim: true)
          |> Enum.map(&parse_tree_entry(&1, prefix))
          |> Enum.sort_by(&{&1.type != "tree", &1.name})

        {:ok, entries}

      {:error, _} ->
        {:error, :not_found}
    end
  end

  defp parse_tree_entry(line, prefix) do
    [meta, name] = String.split(line, "\t", parts: 2)
    [mode, type, oid, size] = meta |> String.split(" ", trim: true)

    %{
      mode: mode,
      type: type,
      oid: oid,
      size: if(size == "-", do: nil, else: String.to_integer(size)),
      name: scrub(name),
      path: prefix <> scrub(name)
    }
  end

  @doc """
  Blob bytes at `path`.

  Returns the raw content plus whether it looks binary and whether it is too
  large to render in the browser.
  """
  @spec blob(Repo.t(), String.t(), String.t()) :: {:ok, map()} | {:error, :not_found}
  def blob(%Repo{dir: dir}, id, path) do
    with {:ok, size} <- object_size(dir, spec(id, path)),
         {:ok, content} <- run(dir, ["cat-file", "blob", spec(id, path)]) do
      {:ok,
       %{
         content: content,
         size: size,
         binary?: binary?(content),
         too_large?: size > @max_render_bytes
       }}
    else
      _ -> {:error, :not_found}
    end
  end

  defp object_size(dir, spec) do
    case run(dir, ["cat-file", "-s", spec]) do
      {:ok, out} -> {:ok, out |> String.trim() |> String.to_integer()}
      {:error, _} -> {:error, :not_found}
    end
  end

  @doc "True when the content holds a NUL byte in its first 8000 bytes."
  @spec binary?(binary()) :: boolean()
  def binary?(content) do
    head = binary_part(content, 0, min(byte_size(content), 8000))
    :binary.match(head, <<0>>) != :nomatch
  end

  @doc "Replaces invalid UTF-8 so git output is safe to render."
  @spec scrub(binary()) :: String.t()
  def scrub(binary) when is_binary(binary) do
    if String.valid?(binary), do: binary, else: String.replace_invalid(binary)
  end

  defp spec(id, ""), do: id <> ":"
  defp spec(id, path), do: id <> ":" <> path

  defp full_object_id?(rev) do
    byte_size(rev) in [40, 64] and Regex.match?(~r/\A[0-9a-fA-F]+\z/, rev)
  end

  defp change_id_prefix?(rev), do: Regex.match?(~r/\A[0-9a-zA-Z]{1,64}\z/, rev)

  defp parse_commits(out) do
    out
    |> String.split(@rs, trim: true)
    |> Enum.map(&String.trim_leading(&1, "\n"))
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(&parse_commit/1)
  end

  defp parse_commit(record) do
    [id, parents, an, ae, ad, cn, ce, cd, change_ids, subject, body] =
      (String.split(record, @us) ++ List.duplicate("", 11)) |> Enum.take(11)

    change_id =
      change_ids
      |> String.split(@cid, trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> List.first()

    %{
      id: id,
      parents: String.split(parents, " ", trim: true),
      author_name: scrub(an),
      author_email: scrub(ae),
      author_date: ad,
      committer_name: scrub(cn),
      committer_email: scrub(ce),
      committer_date: cd,
      change_id: change_id,
      subject: scrub(subject),
      body: scrub(String.trim_trailing(body))
    }
  end

  @doc "Short display form of a commit id."
  @spec short(String.t() | nil) :: String.t()
  def short(nil), do: ""
  def short(id), do: binary_part(id, 0, min(byte_size(id), 12))
end
