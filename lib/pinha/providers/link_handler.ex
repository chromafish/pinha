defmodule Pinha.Providers.LinkHandler do
  @moduledoc """
  Links the account a user just authorized as, from `/settings`.

  The identity comes from the user access token itself. One already linked to
  another Pinha user is refused.
  """

  @behaviour Pinha.Providers.AuthorizationHandler

  alias Pinha.Providers.Accounts
  alias Pinha.Providers.Error

  @impl true
  def handle_authorization(%{user: user, provider: provider, token: token}) do
    with {:ok, identity} <- provider.identity(token),
         {:ok, account} <- Accounts.link(user, provider.name(), identity) do
      {:ok,
       %{
         to: "/settings",
         message: "Linked #{provider.label()} account #{account.login}.",
         audit:
           {"provider_account.linked",
            %{
              provider: account.provider,
              provider_account_id: account.id,
              external_id: account.external_id,
              login: account.login
            }}
       }}
    else
      {:error, :taken} ->
        {:error,
         %{
           to: "/settings",
           message: "That #{provider.label()} account is already linked to another user."
         }}

      {:error, %Error{message: message}} ->
        {:error, %{to: "/settings", message: "#{provider.label()}: #{message}"}}

      {:error, _changeset} ->
        {:error, %{to: "/settings", message: "Could not link the account."}}
    end
  end
end
