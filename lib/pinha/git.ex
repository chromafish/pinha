defmodule Pinha.Git do
  @moduledoc """
  Reads bare repositories by shelling out to `git`.

  Git is the source of truth: there is no metadata store and no index, so
  every call here runs against the repo on disk. The server never runs `jj`.
  It reads the native `change-id` commit header written by current Jujutsu
  clients, with the older message trailer as a compatibility fallback.
  """

  alias Pinha.Config
  alias Pinha.Git.ChangeIdCache
  alias Pinha.Git.Limiter
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
  @stdin_var "PINHA_STDIN"
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

  @type history_kind :: :git | :jj

  @doc "Whether the displayed history carries Jujutsu change identity."
  @spec history_kind([commit()]) :: history_kind()
  def history_kind(commits) when is_list(commits) do
    if Enum.any?(commits, &jj_change?/1), do: :jj, else: :git
  end

  defp jj_change?(%{change_id: change_id}) when is_binary(change_id),
    do: Regex.match?(~r/\A[k-z]{32}\z/i, change_id)

  defp jj_change?(_commit), do: false

  @doc """
  Runs git in `dir` and returns stdout.

  git's stderr is captured rather than inherited: a failure becomes one
  widelog line carrying the repository, the arguments, the exit status, and
  what git said, instead of unstructured text next to the request lines.

  The git process counts against `Pinha.Git.Limiter`. Time spent waiting for
  a slot is recorded on the span as `git.wait_ms`.
  """
  @spec run(String.t(), [String.t()], keyword()) :: {:ok, binary()} | {:error, {:exit, integer()}}
  def run(dir, args, opts \\ []) do
    subcommand = List.first(args) || "git"
    args = ["-c", "core.quotePath=false" | args]
    stderr = stderr_path()
    stdin = write_stdin(Keyword.get(opts, :input))

    Tracer.with_span "git #{subcommand}", %{attributes: span_attributes(dir, subcommand, args)} do
      try do
        {result, wait_ms} =
          Limiter.run(fn ->
            System.cmd("/bin/sh", shell_args(Config.git_bin(), args, stdin != nil),
              cd: dir,
              env: input_env(stdin) ++ [{@stderr_var, stderr} | env(opts)],
              stderr_to_stdout: false
            )
          end)

        Tracer.set_attribute("git.wait_ms", wait_ms)

        case result do
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
        if stdin, do: File.rm(stdin)
      end
    end
  end

  @doc "The attributes every git span carries, whatever started it."
  @spec span_attributes(String.t(), String.t(), [String.t()]) :: [{String.t(), term()}]
  def span_attributes(dir, subcommand, args) do
    [
      {"git.subcommand", subcommand},
      {"git.argv", Enum.map_join(args, " ", &readable/1)},
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
  @spec shell_args(String.t(), [String.t()], boolean()) :: [String.t()]
  def shell_args(bin, args, stdin? \\ false) do
    redirect = if stdin?, do: ~s( <"$#{@stdin_var}"), else: ""
    ["-c", ~s(exec "$@"#{redirect} 2>"$#{@stderr_var}"), "sh", bin | args]
  end

  defp write_stdin(nil), do: nil

  defp write_stdin(input) do
    path = stderr_path()
    File.write!(path, input)
    path
  end

  defp input_env(nil), do: []
  defp input_env(path), do: [{@stdin_var, path}]

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
      argv: Enum.map(args, &readable/1),
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

  @doc "Short name of the existing bookmark `HEAD` points at, or nil without one."
  @spec default_bookmark(Repo.t()) :: String.t() | nil
  def default_bookmark(repo) do
    case refs(repo, tags: false) do
      %{default_bookmark: %{name: name}} -> name
      _ -> nil
    end
  end

  @doc "Compatibility name for `default_bookmark/1`."
  @spec default_branch(Repo.t()) :: String.t() | nil
  def default_branch(repo), do: default_bookmark(repo)

  @doc "Jujutsu bookmarks (Git branches) with their tip commit id, date, and subject."
  @spec bookmarks(Repo.t()) :: [map()]
  def bookmarks(repo), do: refs(repo, tags: false).bookmarks

  @doc "Compatibility name for `bookmarks/1`."
  @spec branches(Repo.t()) :: [map()]
  def branches(repo), do: bookmarks(repo)

  @doc """
  The revision used when a browse URL does not name one.

  Takes the same options as `resolve/3`.
  """
  @spec default_revision(Repo.t(), keyword()) :: map() | nil
  def default_revision(repo, opts \\ []) do
    case refs(repo, tags: false) do
      %{default_bookmark: %{} = bookmark} ->
        target(bookmark.id, :bookmark, bookmark.name, repo, opts)

      _ ->
        case log_all(repo, limit: 1) do
          [commit] ->
            %{id: commit.id, kind: :commit, name: commit.id, change_id: commit.change_id}

          [] ->
            nil
        end
    end
  end

  @doc "Tags with the tag object and, for annotated tags, the commit it peels to."
  @spec tags(Repo.t()) :: [map()]
  def tags(repo), do: refs(repo).tags

  @doc """
  Bookmarks, tags, and the bookmark `HEAD` points at, read with one `git`.

  `default_bookmark` is nil when `HEAD` is detached or names a bookmark that
  does not exist. With `tags: false` only bookmarks are read and `tags` is
  empty.
  """
  @spec refs(Repo.t(), keyword()) :: %{
          default_bookmark: map() | nil,
          bookmarks: [map()],
          tags: [map()]
        }
  def refs(%Repo{dir: dir}, opts \\ []) do
    namespaces =
      if Keyword.get(opts, :tags, true), do: ["refs/heads", "refs/tags"], else: ["refs/heads"]

    format =
      "%(HEAD)#{@us}%(refname)#{@us}%(objectname)#{@us}%(*objectname)#{@us}" <>
        "%(committerdate:iso-strict)#{@us}%(contents:subject)"

    entries =
      case run(dir, ["for-each-ref", "--format=" <> format | namespaces]) do
        {:ok, out} -> out |> String.split("\n", trim: true) |> Enum.flat_map(&parse_ref/1)
        {:error, _} -> []
      end

    %{
      default_bookmark:
        Enum.find_value(entries, fn {kind, head?, ref} -> kind == :bookmark and head? and ref end),
      bookmarks: for({:bookmark, _, ref} <- entries, do: ref),
      tags: for({:tag, _, ref} <- entries, do: ref)
    }
  end

  defp parse_ref(line) do
    [head, refname, oid, peeled, date, subject] =
      (String.split(line, @us, parts: 6) ++ List.duplicate("", 6)) |> Enum.take(6)

    kind_and_name =
      case refname do
        "refs/heads/" <> name -> {:bookmark, name}
        "refs/tags/" <> name -> {:tag, name}
        _ -> nil
      end

    case kind_and_name do
      {kind, name} ->
        [
          {kind, head == "*",
           %{
             name: scrub(name),
             id: if(peeled != "", do: peeled, else: oid),
             ref_id: oid,
             date: date,
             subject: scrub(subject)
           }}
        ]

      nil ->
        []
    end
  end

  @doc """
  Resolves a `:rev` from the URL.

  Full commit id first, then bookmark, then tag, then Jujutsu change id (full or
  unique prefix). Short commit ids are not resolved. An ambiguous change-id
  prefix, or a change id shared by divergent commits, returns every match.

  With `change_id: false`, a commit id, bookmark, or tag resolves with a nil
  `change_id` instead of reading it, for callers that read the commit anyway
  or never show it. A change id match always carries its change id.
  """
  @spec resolve(Repo.t(), String.t(), keyword()) ::
          {:ok, map()} | {:ambiguous, [map()]} | {:error, :not_found}
  def resolve(repo, rev, opts \\ []) when is_binary(rev) do
    with :error <- resolve_commit_id(repo, rev, opts),
         :error <- resolve_ref(repo, rev, opts) do
      resolve_change_id(repo, rev)
    end
  end

  defp resolve_commit_id(%Repo{dir: dir} = repo, rev, opts) do
    if full_object_id?(rev) do
      case run(dir, ["rev-parse", "--verify", "--quiet", "--end-of-options", rev <> "^{commit}"]) do
        {:ok, out} ->
          id = String.trim(out)
          {:ok, target(id, :commit, rev, repo, opts)}

        {:error, _} ->
          :error
      end
    else
      :error
    end
  end

  # A bookmark wins over a tag of the same name.
  defp resolve_ref(repo, rev, opts) do
    %{bookmarks: bookmarks, tags: tags} = refs(repo)

    cond do
      bookmark = Enum.find(bookmarks, &(&1.name == rev)) ->
        {:ok, target(bookmark.id, :bookmark, rev, repo, opts)}

      tag = Enum.find(tags, &(&1.name == rev)) ->
        {:ok, target(tag.id, :tag, rev, repo, opts)}

      true ->
        :error
    end
  end

  defp target(id, kind, name, repo, opts) do
    change_id = if Keyword.get(opts, :change_id, true), do: change_id_of(repo, id)
    %{id: id, kind: kind, name: name, change_id: change_id}
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
  Every commit whose native or legacy change ID starts with `prefix`.

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
        summaries = parse_change_summaries(out)
        native_ids = native_change_ids(dir, Enum.map(summaries, & &1.id))

        summaries
        |> Enum.flat_map(fn summary ->
          summary.id
          |> change_ids_for(summary.trailer_ids, native_ids)
          |> Enum.filter(&String.starts_with?(String.downcase(&1), prefix))
          |> Enum.map(&%{id: summary.id, change_id: &1, subject: summary.subject})
        end)
        |> Enum.uniq_by(& &1.id)

      {:error, _} ->
        []
    end
  end

  @doc "The native or legacy Jujutsu change ID of one commit."
  @spec change_id_of(Repo.t(), String.t()) :: String.t() | nil
  def change_id_of(%Repo{dir: dir}, id) do
    case native_change_ids(dir, [id]) do
      %{^id => change_id} ->
        change_id

      %{} ->
        trailer_change_id(dir, id)
    end
  end

  defp trailer_change_id(dir, id) do
    case run(dir, [
           "show",
           "--no-patch",
           "--format=%(trailers:key=change-id,valueonly,separator=#{@cid})",
           id
         ]) do
      {:ok, out} -> out |> trailer_ids() |> List.first()
      {:error, _} -> nil
    end
  end

  @doc "Recent commits reachable from `rev`, newest first."
  @spec log(Repo.t(), String.t(), keyword()) :: [commit()]
  def log(%Repo{dir: dir}, rev, opts \\ []) do
    log_revisions(dir, [rev], opts)
  end

  @doc "Recent commits reachable from every ref, newest first."
  @spec log_all(Repo.t(), keyword()) :: [commit()]
  def log_all(%Repo{dir: dir}, opts \\ []) do
    log_revisions(dir, ["--all", "--date-order"], opts)
  end

  defp log_revisions(dir, revisions, opts) do
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
        revisions ++ path_args(Keyword.get(opts, :path))

    case run(dir, args) do
      {:ok, out} -> out |> parse_commits() |> attach_native_change_ids(dir)
      {:error, _} -> []
    end
  end

  defp path_args(nil), do: []
  defp path_args(""), do: []
  defp path_args(path), do: ["--", path]

  @doc "One commit's metadata, parents, and Jujutsu change ID."
  @spec commit(Repo.t(), String.t()) :: {:ok, commit()} | {:error, :not_found}
  def commit(%Repo{dir: dir}, id) do
    case run(dir, ["show", "--no-patch", "--no-color", "--format=" <> @commit_format, id]) do
      {:ok, out} ->
        case parse_commits(out) do
          [commit] -> {:ok, commit |> List.wrap() |> attach_native_change_ids(dir) |> hd()}
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
    case run(dir, ["cat-file", "blob", spec(id, path)]) do
      {:ok, content} ->
        size = byte_size(content)

        {:ok,
         %{
           content: content,
           size: size,
           binary?: binary?(content),
           too_large?: size > @max_render_bytes
         }}

      {:error, _} ->
        {:error, :not_found}
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

  # An argument is read by a person, in a log line or on a span. The format
  # strings carry the separators the output is parsed on, and a rev or a path
  # from a URL can be any bytes at all; neither belongs raw in either place.
  defp readable(arg) do
    arg
    |> scrub()
    |> String.replace(~r/[\x00-\x1f\x7f]/, fn <<byte>> ->
      "\\x" <> (byte |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(2, "0"))
    end)
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

  defp attach_native_change_ids([], _dir), do: []

  defp attach_native_change_ids(commits, dir) do
    native_ids = native_change_ids(dir, Enum.map(commits, & &1.id))

    Enum.map(commits, fn commit ->
      %{commit | change_id: Map.get(native_ids, commit.id, commit.change_id)}
    end)
  end

  defp native_change_ids(_dir, []), do: %{}

  # Commits already read on this node come from ChangeIdCache; only the rest
  # go through `cat-file --batch`. The result holds only commits that carry a
  # native header.
  defp native_change_ids(dir, ids) do
    {cached, unread} = ChangeIdCache.lookup(dir, Enum.uniq(ids))
    read = read_native_change_ids(dir, unread)
    ChangeIdCache.put(dir, read)

    cached
    |> Map.merge(read)
    |> Map.reject(fn {_id, change_id} -> is_nil(change_id) end)
  end

  defp read_native_change_ids(_dir, []), do: %{}

  defp read_native_change_ids(dir, ids) do
    input = Enum.map_join(ids, "", &(&1 <> "\n"))

    case run(dir, ["cat-file", "--batch"], input: input) do
      {:ok, out} -> parse_batch_change_ids(out, %{})
      {:error, _} -> %{}
    end
  end

  # Every commit read maps to its native change id, or nil without one. Other
  # object types are skipped, as are names git reports missing or ambiguous.
  defp parse_batch_change_ids("", ids), do: ids

  defp parse_batch_change_ids(out, ids) do
    case :binary.split(out, "\n") do
      [header, rest] ->
        case String.split(header, " ") do
          [id, type, size] -> parse_batch_object(id, type, size, rest, ids)
          [_name, _missing] -> parse_batch_change_ids(rest, ids)
          _ -> ids
        end

      _ ->
        ids
    end
  end

  defp parse_batch_object(id, type, size, rest, ids) do
    with {size, ""} <- Integer.parse(size),
         <<content::binary-size(size), "\n", tail::binary>> <- rest do
      ids = if type == "commit", do: Map.put(ids, id, header_change_id(content)), else: ids
      parse_batch_change_ids(tail, ids)
    else
      _ -> ids
    end
  end

  defp header_change_id(content) do
    content
    |> :binary.split("\n\n")
    |> List.first()
    |> String.split("\n")
    |> Enum.find_value(fn
      "change-id " <> change_id -> present(String.trim(change_id))
      _ -> nil
    end)
  end

  defp parse_change_summaries(out) do
    out
    |> String.split("\n", trim: true)
    |> Enum.flat_map(fn line ->
      case String.split(line, @us) do
        [id, change_ids, subject] ->
          [%{id: id, trailer_ids: trailer_ids(change_ids), subject: scrub(subject)}]

        _ ->
          []
      end
    end)
  end

  defp change_ids_for(id, trailer_ids, native_ids) do
    case Map.fetch(native_ids, id) do
      {:ok, change_id} -> [change_id]
      :error -> trailer_ids
    end
  end

  defp trailer_ids(value) do
    value
    |> String.split(@cid, trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp present(""), do: nil
  defp present(value), do: value

  @doc "Short display form of a commit id."
  @spec short(String.t() | nil) :: String.t()
  def short(nil), do: ""
  def short(id), do: binary_part(id, 0, min(byte_size(id), 12))
end
