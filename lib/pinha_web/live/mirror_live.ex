defmodule PinhaWeb.MirrorLive do
  @moduledoc """
  The mirror panel on a repository page.

  Rendered inside the page rather than routed to, and subscribed to the
  repository's mirror changes, so a sync that starts, finishes, or fails
  reaches the page without anyone reloading it.
  """

  use PinhaWeb, :live_view

  alias Pinha.Accounts
  alias Pinha.Mirroring
  alias Pinha.Mirroring.Mirror
  alias Pinha.Providers
  alias Pinha.Repos

  @impl true
  def mount(_params, session, socket) do
    %{"repo" => name, "user_uid" => uid, "csrf" => csrf} = session

    case Repos.fetch(name) do
      {:ok, repo} ->
        user = user(uid)
        if connected?(socket) and repo.id, do: Mirroring.subscribe(repo.id)

        {:ok, socket |> assign(repo: repo, user: user, csrf: csrf) |> load(), layout: false}

      {:error, _reason} ->
        {:ok,
         assign(socket,
           repo: nil,
           mirror: nil,
           providers: [],
           tone: "neutral",
           signal_label: "unknown",
           pulsing: false
         ), layout: false}
    end
  end

  @impl true
  def handle_info({:mirror, _repo_id, event}, socket) when event in [:queued, :started] do
    {:noreply,
     assign(socket, syncing?: true, tone: "warn", signal_label: "syncing", pulsing: true)}
  end

  def handle_info({:mirror, _repo_id, event}, socket) when event in [:finished, :changed] do
    {:noreply, load(socket)}
  end

  defp user(uid) when is_binary(uid) do
    case Accounts.fetch_user_by_uid(uid) do
      {:ok, user} -> user
      :error -> nil
    end
  end

  defp user(_uid), do: nil

  defp load(%{assigns: %{repo: repo, user: user}} = socket) do
    mirror = Mirroring.for_repo(repo)

    syncing? = repo.id != nil and Mirroring.syncing?(repo.id)
    {tone, label, pulsing} = signal(mirror, syncing?)

    assign(socket,
      mirror: mirror,
      tone: tone,
      signal_label: label,
      pulsing: pulsing,
      syncing?: syncing?,
      may_write: user != nil and Mirroring.may_manage?(repo, user),
      access_url:
        mirror && mirror.state == "awaiting_access" && Mirroring.access_settings_url(mirror),
      providers: providers(repo, user, mirror)
    )
  end

  # The connect form is the owner's, and only for a provider they have linked.
  defp providers(_repo, _user, mirror) when not is_nil(mirror), do: []

  defp providers(repo, user, _mirror) do
    if user && Mirroring.may_connect?(repo, user) do
      accounts = Providers.Accounts.for_user(user)

      for provider <- Providers.with_capability(Mirroring.Capability),
          do: %{provider: provider, account: Map.get(accounts, provider.name())}
    else
      []
    end
  end

  # The lamp: amber while a sync runs, green when the last one succeeded, red
  # when it failed or the mirror is disabled.
  defp signal(nil, true), do: {"warn", "syncing", true}
  defp signal(_mirror, true), do: {"warn", "syncing", true}
  defp signal(nil, _syncing), do: {"neutral", "not mirrored", false}
  defp signal(%Mirror{state: "awaiting_access"}, _), do: {"warn", "awaiting access", false}

  defp signal(%Mirror{state: "disabled"} = mirror, _),
    do: {"danger", "disabled: " <> reason_label(mirror.disabled_reason), false}

  defp signal(%Mirror{} = mirror, _) do
    cond do
      Mirror.failing?(mirror) -> {"danger", "failing", false}
      is_nil(mirror.last_synced_at) -> {"neutral", "never synced", false}
      Mirror.behind?(mirror) -> {"warn", "behind", false}
      true -> {"ok", "in sync", false}
    end
  end

  defp reason_label("user"), do: "switched off here"
  defp reason_label("repository_gone"), do: "the repository is gone"
  defp reason_label("owner_changed"), do: "the repository changed owner"
  defp reason_label("account_unlinked"), do: "the connecting account was unlinked"
  defp reason_label("access_lost"), do: "the connecting user lost write access"
  defp reason_label("installation_removed"), do: "the app was removed"
  defp reason_label("installation_suspended"), do: "the app is suspended"
  defp reason_label("target_unreachable"), do: "the target is out of reach"
  defp reason_label("push_rejected"), do: "the provider refused the push"
  defp reason_label(_reason), do: "unknown"
end
