defmodule PinhaWeb.SettingsController do
  @moduledoc """
  The signed-in user's passkeys and API tokens.

  A token is readable exactly once, on the page that mints it, so creation
  renders rather than redirects.
  """

  use PinhaWeb, :controller

  alias Pinha.Accounts
  alias Pinha.Accounts.WebAuthn

  def show(conn, _params) do
    render_settings(conn, nil)
  end

  def create_token(conn, params) do
    user = conn.assigns.current_user

    case Accounts.create_api_token(user, label(params["label"]), expiry(params["expires_in"])) do
      {:ok, secret, _token} -> render_settings(conn, secret)
      {:error, _changeset} -> fail(conn, 422, "could not create token")
    end
  end

  def delete_token(conn, %{"id" => id}) do
    case Accounts.delete_api_token(conn.assigns.current_user, String.to_integer(id)) do
      :ok -> redirect(conn, to: "/settings")
      {:error, :not_found} -> fail(conn, 404, "no such token")
    end
  end

  def delete_credential(conn, %{"id" => id}) do
    case Accounts.delete_credential(conn.assigns.current_user, String.to_integer(id)) do
      :ok ->
        redirect(conn, to: "/settings")

      {:error, :last_credential} ->
        fail(conn, 409, "this is the only passkey on the account; register another first")

      {:error, :not_found} ->
        fail(conn, 404, "no such passkey")
    end
  end

  def passkey_challenge(conn, params) do
    user = conn.assigns.current_user
    exclude = Enum.map(Accounts.list_credentials(user), & &1.credential_id)
    {options, challenge} = WebAuthn.registration(user.handle, user.email, exclude)

    conn
    |> put_session("challenge", challenge)
    |> put_session("label", label(params["label"]))
    |> json(%{publicKey: options})
  end

  def add_passkey(conn, params) do
    user = conn.assigns.current_user

    with challenge when not is_nil(challenge) <- get_session(conn, "challenge"),
         {:ok, attrs} <- WebAuthn.verify_registration(params, challenge),
         {:ok, _credential} <-
           Accounts.add_credential(user, Map.put(attrs, :label, get_session(conn, "label"))) do
      conn
      |> delete_session("challenge")
      |> json(%{redirect: "/settings"})
    else
      _ -> fail(conn, 403, "could not register that passkey")
    end
  end

  defp render_settings(conn, new_token) do
    user = conn.assigns.current_user

    render(conn, :show,
      credentials: Accounts.list_credentials(user),
      tokens: Accounts.list_api_tokens(user),
      new_token: new_token
    )
  end

  defp label(label) do
    case label |> to_string() |> String.trim() do
      "" -> "token"
      text -> String.slice(text, 0, 80)
    end
  end

  defp expiry(nil), do: nil
  defp expiry(""), do: nil

  defp expiry(days) do
    case Integer.parse(to_string(days)) do
      {days, _} when days > 0 ->
        DateTime.utc_now()
        |> DateTime.add(days * 24 * 3600, :second)
        |> DateTime.truncate(:second)

      _ ->
        nil
    end
  end

  defp fail(conn, status, message), do: PinhaWeb.Failure.send(conn, status, message)
end
