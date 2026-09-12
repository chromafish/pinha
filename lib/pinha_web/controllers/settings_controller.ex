defmodule PinhaWeb.SettingsController do
  @moduledoc """
  The signed-in user's passkeys, API tokens, and SSH keys, and an admin's
  invites.

  A secret is readable exactly once, on the page that mints it, so creation
  renders rather than redirects. A public key is not a secret and is stored as
  pasted, so adding one redirects like any other form.
  """

  use PinhaWeb, :controller

  plug :require_admin when action in [:create_invite, :delete_invite]

  alias Pinha.Accounts
  alias Pinha.Accounts.WebAuthn

  def show(conn, _params) do
    render_settings(conn, nil)
  end

  def update_username(conn, params) do
    user = conn.assigns.current_user
    attrs = username_params(params)

    case Accounts.update_username(user, attrs) do
      {:ok, _user} ->
        conn
        |> put_flash(:info, "Username updated.")
        |> redirect(to: "/settings")

      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> render_settings(nil, nil, changeset)
    end
  end

  defp username_params(params) do
    if is_map(params["user"]) do
      Map.take(params["user"], ["username", :username])
    else
      %{"username" => params["username"]}
    end
  end

  def create_invite(conn, params) do
    case Accounts.create_invite(conn.assigns.current_user, label(params["label"], "invite")) do
      {:ok, secret, _invite} -> render_settings(conn, nil, secret)
      {:error, _changeset} -> fail(conn, 422, "could not mint that invite")
    end
  end

  def delete_invite(conn, %{"id" => id}) do
    case Accounts.delete_invite(String.to_integer(id)) do
      :ok -> redirect(conn, to: "/settings")
      {:error, :not_found} -> fail(conn, 404, "no such invite")
    end
  end

  def create_ssh_key(conn, params) do
    user = conn.assigns.current_user

    case Accounts.add_ssh_key(user, to_string(params["key"]), params["label"]) do
      {:ok, _key} ->
        redirect(conn, to: "/settings")

      {:error, :unreadable} ->
        fail(conn, 422, "that does not look like an SSH public key")

      {:error, :unsupported_algorithm} ->
        fail(conn, 422, "that key type is not accepted; use Ed25519, ECDSA, or RSA")

      {:error, :weak_key} ->
        fail(conn, 422, "an RSA key must be at least 2048 bits")

      {:error, :already_registered} ->
        fail(conn, 409, "that key is already registered")
    end
  end

  def delete_ssh_key(conn, %{"id" => id}) do
    case Accounts.delete_ssh_key(conn.assigns.current_user, String.to_integer(id)) do
      :ok -> redirect(conn, to: "/settings")
      {:error, :not_found} -> fail(conn, 404, "no such key")
    end
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
    {options, challenge} = WebAuthn.registration(user.handle, user.username, exclude)

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

  defp render_settings(conn, new_token, new_invite \\ nil, username_changeset \\ nil) do
    user = conn.assigns.current_user

    render(conn, :show,
      credentials: Accounts.list_credentials(user),
      tokens: Accounts.list_api_tokens(user),
      ssh_keys: Accounts.list_ssh_keys(user),
      ssh_clone_example: PinhaWeb.Helpers.ssh_clone_url("repo"),
      invites: if(user.admin, do: Accounts.list_invites(), else: []),
      new_token: new_token,
      new_invite: new_invite,
      username_changeset: username_changeset || Accounts.change_username(user)
    )
  end

  # Minting an invite is the one thing an ordinary user cannot do, so it is
  # the one thing this page checks.
  defp require_admin(conn, _opts) do
    if conn.assigns.current_user.admin do
      conn
    else
      conn |> fail(403, "only an admin mints invites") |> halt()
    end
  end

  defp label(label, default \\ "token") do
    case label |> to_string() |> String.trim() do
      "" -> default
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
