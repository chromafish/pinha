defmodule Pinha.Mirroring.ConnectHandler do
  @moduledoc """
  Finishes connecting a mirror once the owner has authorized.

  Pinha's side is checked here: the signed-in user still owns the repository
  with the ID the connect started for, it has no mirror yet, and the user
  still has a linked account. The provider's capability then verifies the
  target with the user's token and creates or looks it up. A mirror that
  comes out `active` syncs right away.
  """

  @behaviour Pinha.Providers.AuthorizationHandler

  alias Pinha.Mirroring
  alias Pinha.Mirroring.Capability
  alias Pinha.Providers
  alias Pinha.Providers.Error
  alias Pinha.Repos

  @impl true
  def handle_authorization(%{user: user, provider: provider, params: params} = context) do
    return_to = params["return_to"] || "/"

    with {:ok, repo} <- owned_repository(user, params),
         :ok <- no_mirror(repo),
         {:ok, account} <- linked_account(user, provider),
         {:ok, capability} <- capability(provider),
         {:ok, target} <- capability.connect(Map.put(context, :account, account)),
         {:ok, mirror} <- Mirroring.create(repo, user, account, target) do
      {:ok,
       %{
         to: return_to,
         message: connected_message(mirror, provider),
         audit:
           {"mirror.connected",
            %{
              repo: repo.name,
              repo_id: repo.id,
              mirror_id: mirror.id,
              provider: mirror.provider,
              target_id: mirror.target_id,
              target_name: mirror.target_name,
              state: mirror.state
            }}
       }}
    else
      {:error, %Error{message: message}} ->
        {:error, %{to: return_to, message: "#{provider.label()}: #{message}"}}

      {:error, %Ecto.Changeset{}} ->
        {:error,
         %{to: return_to, message: "That target is already mirrored, or this repository is."}}

      {:error, message} when is_binary(message) ->
        {:error, %{to: return_to, message: message}}
    end
  end

  @impl true
  def handle_incomplete(%{provider: provider, params: params, callback: callback}) do
    message =
      if callback["setup_action"] == "request" do
        "An owner of #{params["account"]} must approve installing the #{provider.label()} app first."
      else
        "The #{provider.label()} authorization did not complete."
      end

    {:error, %{to: params["return_to"] || "/", message: message}}
  end

  defp owned_repository(user, params) do
    case Repos.fetch(params["repo_name"] || "") do
      {:ok, repo} ->
        cond do
          repo.id != params["repo_id"] ->
            {:error, "The repository changed while you were authorizing."}

          not Mirroring.may_connect?(repo, user) ->
            {:error, "Only the repository's owner connects a mirror."}

          true ->
            {:ok, repo}
        end

      {:error, _} ->
        {:error, "The repository is gone."}
    end
  end

  defp no_mirror(repo) do
    if Mirroring.for_repo(repo), do: {:error, "This repository already has a mirror."}, else: :ok
  end

  defp linked_account(user, provider) do
    case Providers.Accounts.get(user, provider.name()) do
      nil -> {:error, "Link your #{provider.label()} account in settings first."}
      account -> {:ok, account}
    end
  end

  defp capability(provider) do
    case Providers.capability(provider, Capability) do
      {:ok, capability} -> {:ok, capability}
      :error -> {:error, "#{provider.label()} does not support mirroring."}
    end
  end

  defp connected_message(%{state: "active"} = mirror, _provider),
    do: "Mirroring to #{mirror.target_name}. The first sync has started."

  defp connected_message(mirror, provider),
    do:
      "Connected to #{mirror.target_name}, but #{provider.label()} cannot reach it yet. " <>
        "Grant the app access to it, then press Check again."
end
