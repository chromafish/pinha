defmodule PinhaWeb.RepoController do
  @moduledoc """
  Repo listing, creation, summary, deletion, and handing one to a new owner.

  Creating is open to any authenticated user, who owns what they create.
  Deleting and reassigning are the owner and admins, the same rule pushing
  follows.
  """

  use PinhaWeb, :controller

  alias Pinha.Accounts
  alias Pinha.Audit
  alias Pinha.Git
  alias Pinha.Parallel
  alias Pinha.Repos

  def index(conn, _params) do
    entries = Parallel.map(Repos.list(), &entry/1)

    case get_format(conn) do
      "json" -> json(conn, %{repos: Enum.map(entries, &json_entry/1)})
      _ -> render(conn, :index, repos: entries)
    end
  end

  def create(conn, params) do
    case Repos.create(params["name"] || "", conn.assigns.current_user) do
      {:ok, repo} ->
        conn = Audit.put(conn, "repo.created", conn.assigns.current_user, %{repo: repo.name})

        case get_format(conn) do
          "json" ->
            conn
            |> put_status(:created)
            |> put_resp_header("location", PinhaWeb.Helpers.repo_path(repo.name))
            |> json(%{
              name: repo.name,
              repository_model: Atom.to_string(repo.kind),
              url: PinhaWeb.Helpers.clone_url(repo.name)
            })

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
        may_write = Repos.writable_by?(repo, conn.assigns.current_user)

        [refs, commits, {owner, users}] =
          Parallel.all([
            fn -> Git.refs(repo) end,
            fn -> Git.log_all(repo, limit: 20) end,
            fn -> owner_and_users(repo, may_write) end
          ])

        render(conn, :show,
          repo: repo,
          owner: owner,
          may_write: may_write,
          users: users,
          default_bookmark: refs.default_bookmark && refs.default_bookmark.name,
          bookmarks: refs.bookmarks,
          tags: refs.tags,
          commits: commits,
          repo_kind: presentation_kind(repo, Git.history_kind(commits))
        )

      {:error, :invalid_name} ->
        fail(conn, 400, "invalid repository name")

      {:error, :invalid_repo} ->
        fail(conn, 500, "not a valid bare repository")

      {:error, :not_found} ->
        fail(conn, 404, "no such repository")
    end
  end

  def set_owner(conn, %{"repo" => name} = params) do
    username = params["username"] || params["email"] || ""

    with {:ok, repo} <- Repos.fetch(name),
         true <- Repos.writable_by?(repo, conn.assigns.current_user),
         {:ok, new_repo} <- Repos.set_owner(name, to_string(username)) do
      {:ok, target} = Accounts.fetch_user_by_username(to_string(username))

      conn
      |> Audit.put("repo.owner_changed", conn.assigns.current_user, %{
        repo: repo.name,
        old_owner_uid: repo.owner_uid,
        new_owner_id: target.id,
        new_owner_uid: target.uid,
        new_owner_username: target.username
      })
      |> redirect(to: PinhaWeb.Helpers.repo_path(new_repo.name))
    else
      false -> fail(conn, 403, "only the owner or an admin hands over a repository")
      {:error, :no_such_user} -> fail(conn, 404, "no user with that username")
      {:error, :invalid_name} -> fail(conn, 400, "invalid repository name")
      {:error, :not_found} -> fail(conn, 404, "no such repository")
      {:error, :invalid_repo} -> fail(conn, 500, "not a valid bare repository")
      {:error, :failed} -> fail(conn, 500, "could not set the owner")
    end
  end

  def delete(conn, %{"repo" => name}) do
    with {:ok, repo} <- Repos.fetch(name),
         true <- Repos.writable_by?(repo, conn.assigns.current_user) do
      destroy(conn, repo.name)
    else
      false ->
        fail(conn, 403, "only the owner or an admin deletes a repository")

      {:error, :invalid_name} ->
        fail(conn, 400, "invalid repository name")

      {:error, :invalid_repo} ->
        fail(conn, 500, "not a valid bare repository")

      {:error, :not_found} ->
        fail(conn, 404, "no such repository")
    end
  end

  defp destroy(conn, name) do
    case Repos.delete(name) do
      :ok ->
        conn = Audit.put(conn, "repo.deleted", conn.assigns.current_user, %{repo: name})

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

  # The owner picker lists every user, and the owner is one of them, so a
  # writer's page reads users once.
  defp owner_and_users(repo, true) do
    users = Accounts.list_users()
    {repo.owner_uid && Enum.find(users, &(&1.uid == repo.owner_uid)), users}
  end

  defp owner_and_users(repo, false) do
    case Repos.owner(repo) do
      {:ok, user} -> {user, []}
      :error -> {nil, []}
    end
  end

  defp entry(repo) do
    [refs, commits] =
      Parallel.all([
        fn -> Git.refs(repo, tags: false) end,
        fn -> Git.log_all(repo, limit: 20) end
      ])

    repo_kind = presentation_kind(repo, Git.history_kind(commits))
    default_bookmark = refs.default_bookmark

    # The default bookmark's tip is usually among the newest commits already
    # read, which saves a second log.
    head =
      case {repo_kind, default_bookmark} do
        {:git, %{id: id}} ->
          Enum.find(commits, &(&1.id == id)) || repo |> Git.log(id, limit: 1) |> List.first()

        _ ->
          List.first(commits)
      end

    %{
      repo: repo,
      repo_kind: repo_kind,
      default_bookmark: default_bookmark && default_bookmark.name,
      head: head
    }
  end

  defp json_entry(%{
         repo: repo,
         repo_kind: repo_kind,
         default_bookmark: bookmark,
         head: head
       }) do
    %{
      name: repo.name,
      description: repo.description,
      repository_model: Atom.to_string(repo.kind),
      history_model: if(repo_kind == :git, do: "git", else: "jujutsu"),
      default_bookmark: bookmark,
      default_branch: bookmark,
      head: head && %{id: head.id, subject: head.subject, change_id: head.change_id},
      clone_url: PinhaWeb.Helpers.clone_url(repo.name),
      ssh_clone_url: PinhaWeb.Helpers.ssh_clone_url(repo.name)
    }
  end

  defp presentation_kind(%{kind: :jj}, _history_kind), do: :jj
  defp presentation_kind(%{kind: :git}, :jj), do: :jj_via_git
  defp presentation_kind(%{kind: :git}, :git), do: :git

  defp fail(conn, status, message), do: PinhaWeb.Failure.send(conn, status, message)
end
