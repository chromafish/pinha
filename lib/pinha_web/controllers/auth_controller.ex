defmodule PinhaWeb.AuthController do
  @moduledoc """
  Sign-up, sign-in, and sign-out.

  Both ceremonies are two requests: one that hands the browser a challenge and
  remembers it in the session, and one that carries the authenticator's answer
  back. The pages themselves are plain HTML; the only script involved calls
  `navigator.credentials`.
  """

  use PinhaWeb, :controller

  import PinhaWeb.UserAuth, only: [log_in_user: 2, log_out_user: 1]

  require Logger

  alias Pinha.Accounts
  alias Pinha.Accounts.Registration
  alias Pinha.Accounts.User
  alias Pinha.Accounts.WebAuthn

  plug :redirect_if_signed_in when action in [:new_signup, :new_session]

  def new_signup(conn, params) do
    render(conn, :signup,
      first?: Accounts.count_users() == 0,
      claim: params["claim"] |> to_string() |> String.trim()
    )
  end

  def new_session(conn, _params) do
    render(conn, :signin)
  end

  @doc """
  Hands out a registration challenge.

  The same endpoint serves a claim, an invite, and an operator-authorized
  recovery, because all three end in the same ceremony: what differs is the
  token that admitted it, which is remembered here and spent when the
  credential lands.
  """
  def signup_challenge(conn, %{"email" => email, "label" => label} = params) do
    case registration_mode(email, params) do
      {:new, email, authorization} ->
        username = params["username"] |> to_string()

        with :ok <- validate_username(username) do
          handle = User.generate_handle()
          {options, challenge} = WebAuthn.registration(handle, username)

          conn
          |> remember(
            challenge,
            [username: username, email: email, label: label(label), handle: handle, mode: "new"] ++
              List.wrap(authorization)
          )
          |> json(%{publicKey: options})
        else
          {:error, message} -> fail(conn, 422, message)
        end

      {:recovery, user} ->
        exclude = Enum.map(Accounts.list_credentials(user), & &1.credential_id)
        {options, challenge} = WebAuthn.registration(user.handle, user.username, exclude)

        conn
        |> remember(challenge, email: user.email, label: label(label), mode: "recovery")
        |> json(%{publicKey: options})

      {:error, message} ->
        fail(conn, 403, message)
    end
  end

  def signup_challenge(conn, _params),
    do: fail(conn, 400, "username, email and label are required")

  defp validate_username(username) do
    cond do
      String.trim(username) == "" ->
        {:error, "username can't be blank"}

      String.length(username) > 64 ->
        {:error, "username is too long"}

      match?({:ok, _}, Accounts.fetch_user_by_username(username)) ->
        {:error, "username has already been taken"}

      true ->
        :ok
    end
  end

  def signup(conn, params) do
    with {:ok, challenge} <- recall(conn, "challenge"),
         {:ok, attrs} <- WebAuthn.verify_registration(params, challenge) do
      complete_signup(conn, get_session(conn, "mode"), attrs)
    else
      {:error, reason} -> fail(conn, 403, "registration failed: #{inspect(reason)}")
    end
  end

  defp complete_signup(conn, "new", attrs) do
    username = get_session(conn, "username")
    email = get_session(conn, "email")
    handle = get_session(conn, "handle")
    attrs = Map.put(attrs, :label, get_session(conn, "label"))

    case authorization(conn) do
      {:claim, token} ->
        # Spending the claim before the insert is what stops two holders of
        # one token from both registering. A ceremony that fails after this
        # needs a fresh token from the console, which is the cheap direction
        # for the mistake to fall in.
        if Registration.consume_claim(token),
          do:
            register(
              conn,
              %{username: username, email: email, handle: handle, admin: true},
              attrs,
              []
            ),
          else: fail(conn, 403, "that claim token has been spent")

      {:invite, invite} ->
        register(conn, %{username: username, email: email, handle: handle}, attrs, invite: invite)

      :error ->
        fail(conn, 403, "that registration is no longer authorized")
    end
  end

  defp complete_signup(conn, "recovery", attrs) do
    email = get_session(conn, "email")

    with {:ok, user} <- Accounts.fetch_user_by_email(email),
         true <- Registration.consume(email),
         {:ok, _credential} <-
           Accounts.add_credential(user, Map.put(attrs, :label, get_session(conn, "label"))) do
      conn |> log_in_user(user) |> json(%{redirect: "/"})
    else
      false -> fail(conn, 403, "recovery window has closed")
      :error -> fail(conn, 403, "no such user")
      {:error, changeset} -> fail(conn, 422, errors(changeset))
    end
  end

  defp complete_signup(conn, _mode, _attrs), do: fail(conn, 403, "no registration in progress")

  defp register(conn, user_attrs, credential_attrs, opts) do
    case Accounts.register_user(user_attrs, credential_attrs, opts) do
      {:ok, %{user: user}} ->
        conn |> log_in_user(user) |> json(%{redirect: "/"})

      {:error, :invite, :invite_spent} ->
        fail(conn, 403, "that invite has already been used")

      {:error, _step, changeset} ->
        fail(conn, 422, errors(changeset))
    end
  end

  def signin_challenge(conn, _params) do
    {options, challenge} = WebAuthn.authentication()

    conn
    |> remember(challenge, [])
    |> json(%{publicKey: options})
  end

  def signin(conn, params) do
    with {:ok, challenge} <- recall(conn, "challenge"),
         {:ok, handle} <- WebAuthn.user_handle(params),
         {:ok, user} <- Accounts.fetch_user_by_handle(handle),
         {:ok, credential_id, sign_count} <-
           WebAuthn.verify_authentication(params, challenge, Accounts.credential_keys(user)),
         {:ok, _credential} <- Accounts.record_authentication(user, credential_id, sign_count) do
      conn |> log_in_user(user) |> json(%{redirect: "/"})
    else
      {:error, :counter_did_not_advance} ->
        Logger.warning("refused an assertion whose signature counter did not advance")
        fail(conn, 403, "this passkey looks cloned; register a new one")

      other ->
        Logger.warning("sign-in failed: #{inspect(other)}")
        fail(conn, 403, "sign-in failed")
    end
  end

  def delete(conn, _params) do
    conn
    |> log_out_user()
    |> redirect(to: "/signin")
  end

  ## Ceremony state

  # The challenge, and what the answer will be attached to, live in the
  # session for the seconds the authenticator is busy.
  defp remember(conn, challenge, fields) do
    Enum.reduce(fields, put_session(conn, "challenge", challenge), fn {key, value}, conn ->
      put_session(conn, to_string(key), value)
    end)
  end

  defp recall(conn, key) do
    case get_session(conn, key) do
      nil -> {:error, :no_challenge}
      value -> {:ok, value}
    end
  end

  # A registration is admitted by a token and nothing else: the claim token on
  # a server nobody has claimed, an invite on one that has users, and a
  # recovery window for an address that already has an account.
  defp registration_mode(email, params) do
    email = email |> to_string() |> String.trim() |> String.downcase()

    case Accounts.fetch_user_by_email(email) do
      {:ok, user} ->
        if Registration.authorized?(email),
          do: {:recovery, user},
          else: {:error, "sign-up is not available for that address"}

      :error ->
        admit(email, params)
    end
  end

  defp admit(email, params) do
    if Accounts.count_users() == 0 do
      token = field(params, "claim")

      if Registration.claim?(token),
        do: {:new, email, {:claim, token}},
        else: {:error, "no one has claimed this server yet; paste the claim token from its log"}
    else
      case Accounts.fetch_usable_invite(field(params, "invite")) do
        {:ok, invite} -> {:new, email, {:invite, invite.id}}
        :error -> {:error, "that invite is spent, expired, or was never minted"}
      end
    end
  end

  # The session carries the row id rather than the invite itself, so the
  # invite is read again, and spent, against the database it lives in.
  defp authorization(conn) do
    case {get_session(conn, "claim"), get_session(conn, "invite")} do
      {token, _} when is_binary(token) ->
        {:claim, token}

      {_, id} when is_integer(id) ->
        case Accounts.fetch_usable_invite_by_id(id) do
          {:ok, invite} -> {:invite, invite}
          :error -> :error
        end

      _ ->
        :error
    end
  end

  defp field(params, key), do: params |> Map.get(key, "") |> to_string() |> String.trim()

  defp label(label) do
    case label |> to_string() |> String.trim() do
      "" -> "passkey"
      text -> String.slice(text, 0, 80)
    end
  end

  defp errors(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {message, _opts} -> message end)
    |> Enum.map_join("; ", fn {field, messages} -> "#{field} #{Enum.join(messages, ", ")}" end)
  end

  defp fail(conn, status, message), do: PinhaWeb.Failure.send(conn, status, message)

  defp redirect_if_signed_in(conn, _opts) do
    if conn.assigns[:current_user] do
      conn |> redirect(to: "/") |> halt()
    else
      conn
    end
  end
end
