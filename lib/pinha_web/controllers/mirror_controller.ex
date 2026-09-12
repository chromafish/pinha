defmodule PinhaWeb.MirrorController do
  @moduledoc """
  The repository page's mirror controls.

  The owner connects a mirror; the owner and admins enable, disable,
  disconnect, sync it, and check its access again. Every control is audited,
  and every one answers by returning to the repository page with what
  happened.
  """

  use PinhaWeb, :controller

  alias Pinha.Audit
  alias Pinha.Mirroring
  alias Pinha.Repos

  def connect(conn, %{"repo" => name} = params) do
    with {:ok, repo} <- fetch_repo(conn, name) do
      case Mirroring.start_connect(conn.assigns.current_user, repo, params["provider"], params) do
        {:ok, url} ->
          conn
          |> Audit.put("mirror.connect_started", conn.assigns.current_user, %{
            repo: repo.name,
            provider: params["provider"],
            account: params["account"],
            target: params["name"]
          })
          |> redirect(external: url)

        {:error, message} ->
          back(conn, repo, :error, message)
      end
    else
      {:error, conn} -> conn
    end
  end

  def sync(conn, %{"repo" => name}) do
    with {:ok, repo, mirror} <- fetch_mirror(conn, name) do
      case Mirroring.sync_now(mirror, "manual") do
        {:ok, _job} -> audited(conn, repo, mirror, "mirror.sync_requested", "Sync started.")
        {:error, message} -> back(conn, repo, :error, message)
      end
    else
      {:error, conn} -> conn
    end
  end

  def enable(conn, %{"repo" => name}) do
    with {:ok, repo, mirror} <- fetch_mirror(conn, name) do
      case Mirroring.enable(mirror) do
        {:ok, _mirror} ->
          audited(conn, repo, mirror, "mirror.enabled", "Mirror enabled; a sync has started.")

        {:error, message} ->
          back(conn, repo, :error, "The mirror stays disabled: #{message}")
      end
    else
      {:error, conn} -> conn
    end
  end

  def disable(conn, %{"repo" => name}) do
    with {:ok, repo, mirror} <- fetch_mirror(conn, name) do
      {:ok, _mirror} = Mirroring.disable(mirror)
      audited(conn, repo, mirror, "mirror.disabled", "Mirror disabled. The target is untouched.")
    else
      {:error, conn} -> conn
    end
  end

  def check(conn, %{"repo" => name}) do
    with {:ok, repo, mirror} <- fetch_mirror(conn, name) do
      case Mirroring.check_again(mirror) do
        {:ok, _mirror} ->
          audited(
            conn,
            repo,
            mirror,
            "mirror.access_checked",
            "The target is reachable; syncing."
          )

        {:error, message} ->
          back(conn, repo, :error, message)
      end
    else
      {:error, conn} -> conn
    end
  end

  def disconnect(conn, %{"repo" => name}) do
    with {:ok, repo, mirror} <- fetch_mirror(conn, name) do
      :ok = Mirroring.disconnect(mirror)

      audited(
        conn,
        repo,
        mirror,
        "mirror.disconnected",
        "Mirror disconnected. The target is untouched."
      )
    else
      {:error, conn} -> conn
    end
  end

  defp fetch_repo(conn, name) do
    case Repos.fetch(name) do
      {:ok, repo} ->
        if Mirroring.may_manage?(repo, conn.assigns.current_user) do
          {:ok, repo}
        else
          {:error,
           PinhaWeb.Failure.send(conn, 403, "only the owner or an admin manages a mirror")}
        end

      {:error, :not_found} ->
        {:error, PinhaWeb.Failure.send(conn, 404, "no such repository")}

      {:error, :invalid_name} ->
        {:error, PinhaWeb.Failure.send(conn, 400, "invalid repository name")}

      {:error, :invalid_repo} ->
        {:error, PinhaWeb.Failure.send(conn, 500, "not a valid bare repository")}
    end
  end

  defp fetch_mirror(conn, name) do
    with {:ok, repo} <- fetch_repo(conn, name) do
      case Mirroring.for_repo(repo) do
        nil -> {:error, PinhaWeb.Failure.send(conn, 404, "this repository has no mirror")}
        mirror -> {:ok, repo, mirror}
      end
    end
  end

  defp audited(conn, repo, mirror, event, message) do
    conn
    |> Audit.put(event, conn.assigns.current_user, %{
      repo: repo.name,
      mirror_id: mirror.id,
      provider: mirror.provider,
      target_name: mirror.target_name
    })
    |> back(repo, :info, message)
  end

  defp back(conn, repo, level, message) do
    conn
    |> put_flash(level, message)
    |> redirect(to: PinhaWeb.Helpers.repo_path(repo.name))
  end
end
