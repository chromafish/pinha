defmodule PinhaWeb.BrowseController do
  @moduledoc """
  Tree, blob, raw, and commit views.

  A `:rev` resolves as full commit id first, then bookmark, then tag, then
  Jujutsu change id; an ambiguous change-id prefix lists every match.
  """

  use PinhaWeb, :controller

  alias Pinha.Git
  alias Pinha.Parallel
  alias Pinha.Repos

  def tree(conn, %{"repo" => name} = params) do
    with_target(conn, name, params["rev"], fn conn, repo, target ->
      case browse_path(params) do
        :error ->
          fail(conn, 400, "invalid path")

        {:ok, path} ->
          [change_id, contents] =
            Parallel.all([
              fn -> target.change_id || Git.change_id_of(repo, target.id) end,
              fn -> path_contents(repo, target.id, path) end
            ])

          target = %{target | change_id: change_id}

          case contents do
            {:tree, entries, commits} ->
              readme = readme_for_tree(repo, target, path)
              render_tree(conn, repo, target, path, entries, commits, readme)

            {:blob, blob} ->
              render_blob(conn, repo, target, path, blob)

            :error ->
              fail(conn, 404, "no such path at this revision")
          end
      end
    end)
  end

  def raw(conn, %{"repo" => name} = params) do
    with_target(conn, name, params["rev"], fn conn, repo, target ->
      case browse_path(params) do
        :error ->
          fail(conn, 400, "invalid path")

        {:ok, path} ->
          with {:ok, "blob"} <- Git.object_type(repo, target.id, path),
               {:ok, blob} <- Git.blob(repo, target.id, path) do
            conn
            |> put_resp_header("content-type", "application/octet-stream")
            |> put_resp_header("x-content-type-options", "nosniff")
            |> put_resp_header("content-disposition", disposition(path))
            |> send_resp(200, blob.content)
          else
            _ -> fail(conn, 404, "no such file at this revision")
          end
      end
    end)
  end

  def commit(conn, %{"repo" => name, "id" => id}) do
    with_target(conn, name, id, fn conn, repo, target ->
      [commit, stat, diff] =
        Parallel.all([
          fn -> Git.commit(repo, target.id) end,
          fn -> Git.diff_stat(repo, target.id) end,
          fn -> Git.diff(repo, target.id) end
        ])

      case commit do
        {:ok, commit} ->
          render(conn, :commit,
            repo: repo,
            commit: commit,
            stat: stat,
            diff: diff,
            page_title: "#{repo.name}: #{Git.short(commit.id)}"
          )

        {:error, :not_found} ->
          fail(conn, 404, "no such commit")
      end
    end)
  end

  # A commit's root is always a tree, so the root skips the type check.
  defp path_contents(repo, id, ""), do: tree_contents(repo, id, "")

  defp path_contents(repo, id, path) do
    case Git.object_type(repo, id, path) do
      {:ok, "tree"} ->
        tree_contents(repo, id, path)

      {:ok, "blob"} ->
        case Git.blob(repo, id, path) do
          {:ok, blob} -> {:blob, blob}
          {:error, :not_found} -> :error
        end

      _ ->
        :error
    end
  end

  defp tree_contents(repo, id, path) do
    case Parallel.all([
           fn -> Git.list_tree(repo, id, path) end,
           fn -> Git.log(repo, id, limit: 10, path: path) end
         ]) do
      [{:ok, entries}, commits] -> {:tree, entries, commits}
      [{:error, :not_found}, _commits] -> :error
    end
  end

  defp render_tree(conn, repo, target, path, entries, commits, readme) do
    render(conn, :tree,
      repo: repo,
      target: target,
      path: path,
      entries: entries,
      commits: commits,
      readme: readme,
      page_title: "#{repo.name}: #{path}"
    )
  end

  defp readme_for_tree(repo, target, path) do
    case Git.readme(repo, target.id, path) do
      {:ok, %{content: content, kind: kind, filename: filename}} ->
        html = PinhaWeb.Markdown.to_html(content, kind, repo.name, target.name, path)

        %{
          filename: filename,
          kind: kind,
          html: html
        }

      :not_found ->
        nil
    end
  end

  defp render_blob(conn, repo, target, path, blob) do
    render(conn, :blob,
      repo: repo,
      target: target,
      path: path,
      blob: blob,
      lines: blob_lines(blob),
      page_title: "#{repo.name}: #{path}"
    )
  end

  defp blob_lines(%{binary?: true}), do: []
  defp blob_lines(%{too_large?: true}), do: []
  defp blob_lines(%{content: content}), do: content |> Git.scrub() |> String.split("\n")

  # Resolves the repo and revision. Without one, an existing HEAD bookmark wins;
  # a bookmarkless repository uses its newest reachable commit.
  #
  # The target's change id is left nil unless the rev was a change id: the
  # commit page reads it with the commit, and the tree page reads it alongside
  # the path, so resolving never waits on it.
  defp with_target(conn, name, rev, fun) do
    case Repos.fetch(name) do
      {:ok, repo} ->
        opts = [change_id: false]

        case if(rev, do: Git.resolve(repo, rev, opts), else: default_target(repo, opts)) do
          nil ->
            fail(conn, 404, "repository has no revisions")

          {:ok, target} ->
            fun.(conn, repo, target)

          {:ambiguous, matches} ->
            conn
            |> put_status(300)
            |> render(:ambiguous, repo: repo, rev: rev, matches: matches)

          {:error, :not_found} ->
            fail(conn, 404, "no such revision")
        end

      {:error, :invalid_name} ->
        fail(conn, 400, "invalid repository name")

      {:error, :invalid_repo} ->
        fail(conn, 500, "not a valid bare repository")

      {:error, :not_found} ->
        fail(conn, 404, "no such repository")
    end
  end

  defp default_target(repo, opts) do
    case Git.default_revision(repo, opts) do
      nil -> nil
      target -> {:ok, target}
    end
  end

  # A path is a list of plain segments. Percent-encoded separators decode into
  # the segment itself, so the check runs over the joined path as well.
  defp browse_path(params) do
    segments = Map.get(params, "path", [])

    with true <- is_list(segments),
         path = Enum.join(segments, "/"),
         false <- String.contains?(path, <<0>>),
         parts = String.split(path, "/"),
         true <- path == "" or Enum.all?(parts, &(&1 not in ["", ".", ".."])) do
      {:ok, path}
    else
      _ -> :error
    end
  end

  defp disposition(path) do
    name = path |> Path.basename() |> String.replace(~r/["\r\n\\]/, "")
    ~s(inline; filename="#{name}")
  end

  defp fail(conn, status, message), do: PinhaWeb.Failure.send(conn, status, message)
end
