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
          case Git.object_type(repo, target.id, path) do
            {:ok, "tree"} -> render_tree(conn, repo, target, path)
            {:ok, "blob"} -> render_blob(conn, repo, target, path)
            _ -> fail(conn, 404, "no such path at this revision")
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

  defp render_tree(conn, repo, target, path) do
    [{:ok, entries}, commits] =
      Parallel.all([
        fn -> Git.list_tree(repo, target.id, path) end,
        fn -> Git.log(repo, target.id, limit: 10, path: path) end
      ])

    render(conn, :tree,
      repo: repo,
      target: target,
      path: path,
      entries: entries,
      commits: commits,
      page_title: "#{repo.name}: #{path}"
    )
  end

  defp render_blob(conn, repo, target, path) do
    {:ok, blob} = Git.blob(repo, target.id, path)

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
  defp with_target(conn, name, rev, fun) do
    case Repos.fetch(name) do
      {:ok, repo} ->
        case if(rev, do: Git.resolve(repo, rev), else: default_target(repo)) do
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

  defp default_target(repo) do
    case Git.default_revision(repo) do
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
