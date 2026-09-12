defmodule Pinha.Providers.GitHub do
  @moduledoc """
  GitHub, through one GitHub App the operator registers for the server.

  The app has user authorization during installation turned on, so
  installing and authorizing are one round trip to the same callback. Its
  private key mints installation tokens; its client ID and secret exchange
  and revoke user access tokens; its webhook secret verifies deliveries.

  Deliveries become provider events:

    * `installation_removed` and `installation_suspended`, with
      `installation_id`;
    * `repositories_removed`, with `installation_id` and `repository_ids`;
    * `repository_deleted` and `repository_transferred`, with
      `repository_id`;
    * `repository_renamed`, with `repository_id`, `name`, and `url`;
    * `authorization_revoked`, with the GitHub user's `external_id`.
  """

  @behaviour Pinha.Providers.Provider

  alias Pinha.Providers.GitHub.Client
  alias Pinha.Providers.GitHub.Config

  @impl true
  def name, do: "github"

  @impl true
  def label, do: "GitHub"

  @impl true
  def configured?, do: Config.configured?()

  @impl true
  def capabilities, do: %{Pinha.Mirroring.Capability => Pinha.Providers.GitHub.Mirroring}

  @impl true
  def authorization_url(state, opts \\ []) do
    if Keyword.get(opts, :install, false) do
      Config.web_url() <>
        "/apps/#{Config.app_slug()}/installations/new?" <> URI.encode_query(%{"state" => state})
    else
      Config.web_url() <>
        "/login/oauth/authorize?" <>
        URI.encode_query(%{"client_id" => Config.client_id(), "state" => state})
    end
  end

  @impl true
  def exchange_code(code), do: Client.exchange_code(code)

  @impl true
  def identity(token) do
    case Client.request(:get, "/user", auth: {:bearer, token}) do
      {:ok, %{body: %{"id" => id, "login" => login}}} ->
        {:ok, %{external_id: to_string(id), login: login}}

      {:ok, _response} ->
        {:error, Pinha.Providers.Error.transient("GitHub did not say who the token belongs to")}

      {:error, error} ->
        {:error, error}
    end
  end

  @impl true
  def revoke_token(token), do: Client.revoke(token)

  @impl true
  def verify_delivery(headers, body) do
    with "sha256=" <> signature <- Map.get(headers, "x-hub-signature-256", ""),
         delivery_id when is_binary(delivery_id) and delivery_id != "" <-
           Map.get(headers, "x-github-delivery") do
      expected =
        :hmac
        |> :crypto.mac(:sha256, Config.webhook_secret(), body)
        |> Base.encode16(case: :lower)

      if Plug.Crypto.secure_compare(expected, String.downcase(signature)) do
        {:ok, delivery_id}
      else
        {:error, :invalid_signature}
      end
    else
      _ -> {:error, :invalid_signature}
    end
  end

  @impl true
  def events(headers, payload) do
    event(Map.get(headers, "x-github-event"), payload)
  end

  defp event("installation", %{"action" => "deleted", "installation" => %{"id" => id}}),
    do: [%{"type" => "installation_removed", "installation_id" => to_string(id)}]

  defp event("installation", %{"action" => "suspend", "installation" => %{"id" => id}}),
    do: [%{"type" => "installation_suspended", "installation_id" => to_string(id)}]

  defp event("installation_repositories", %{
         "action" => "removed",
         "installation" => %{"id" => id},
         "repositories_removed" => repositories
       }) do
    [
      %{
        "type" => "repositories_removed",
        "installation_id" => to_string(id),
        "repository_ids" => Enum.map(repositories, &to_string(&1["id"]))
      }
    ]
  end

  defp event("repository", %{"action" => action, "repository" => %{"id" => id}})
       when action in ["deleted", "transferred"] do
    [%{"type" => "repository_" <> action, "repository_id" => to_string(id)}]
  end

  defp event("repository", %{"action" => "renamed", "repository" => repository}) do
    [
      %{
        "type" => "repository_renamed",
        "repository_id" => to_string(repository["id"]),
        "name" => repository["full_name"],
        "url" => repository["html_url"]
      }
    ]
  end

  defp event("github_app_authorization", %{"action" => "revoked", "sender" => %{"id" => id}}),
    do: [%{"type" => "authorization_revoked", "external_id" => to_string(id)}]

  defp event(_name, _payload), do: []
end
