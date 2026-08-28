defmodule PinhaWeb.RepoController do
  @moduledoc "Repo listing, creation, summary, and deletion."

  use PinhaWeb, :controller

  alias Pinha.Git
  alias Pinha.Repos

  def index(conn, _params) do
    entries = Enum.map(Repos.list(), &entry/1)

    case get_format(conn) do
      "json" -> json(conn, %{repos: Enum.map(entries, &json_entry/1)})
      _ -> render(conn, :index, repos: entries)
    end
  end

  def create(conn, params) do
    case Repos.create(params["name"] || "") do
      {:ok, repo} ->
        case get_format(conn) do
          "json" ->
            conn
            |> put_status(:created)
            |> put_resp_header("location", PinhaWeb.Helpers.repo_path(repo.name))
            |> json(%{name: repo.name, url: PinhaWeb.Helpers.clone_url(repo.name)})

          _ ->
            redirect(conn, to: PinhaWeb.Helpers.repo_path(repo.name))
        end

      {:error, :invalid_name} ->
        fail(conn, 422, "invalid repository name")

      {:error, :exists} ->
        fail(conn, 409, "repository already exists")

      {:error, :failed} ->
        fail(conn, 500, "could not create repository")
    end
  end

  def show(conn, %{"repo" => name}) do
    case Repos.fetch(name) do
      {:ok, repo} ->
        branch = Git.default_branch(repo)
        branches = Git.branches(repo)
        tags = Git.tags(repo)
        commits = if branch, do: Git.log(repo, branch, limit: 20), else: []

        render(conn, :show,
          repo: repo,
          default_branch: branch,
          branches: branches,
          tags: tags,
          commits: commits
        )

      {:error, :invalid_name} ->
        fail(conn, 400, "invalid repository name")

      {:error, :invalid_repo} ->
        fail(conn, 500, "not a valid bare repository")

      {:error, :not_found} ->
        fail(conn, 404, "no such repository")
    end
  end

  def delete(conn, %{"repo" => name}) do
    case Repos.delete(name) do
      :ok ->
        case get_format(conn) do
          "json" -> send_resp(conn, 204, "")
          _ -> redirect(conn, to: "/")
        end

      {:error, :invalid_name} ->
        fail(conn, 400, "invalid repository name")

      {:error, :not_found} ->
        fail(conn, 404, "no such repository")

      {:error, :failed} ->
        fail(conn, 500, "could not delete repository")
    end
  end

  defp entry(repo) do
    branch = Git.default_branch(repo)

    head =
      case branch && Git.log(repo, branch, limit: 1) do
        [commit] -> commit
        _ -> nil
      end

    %{repo: repo, default_branch: branch, head: head}
  end

  defp json_entry(%{repo: repo, default_branch: branch, head: head}) do
    %{
      name: repo.name,
      description: repo.description,
      default_branch: branch,
      head: head && %{id: head.id, subject: head.subject, change_id: head.change_id},
      clone_url: PinhaWeb.Helpers.clone_url(repo.name)
    }
  end

  defp fail(conn, status, message), do: PinhaWeb.Failure.send(conn, status, message)
end
