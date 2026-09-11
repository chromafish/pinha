defmodule PinhaWeb.UserAuth do
  @moduledoc """
  Who is making this request, and may they.

  Browsers carry a session cookie minted by a passkey ceremony. Git carries an
  API token over HTTP Basic, because a git client cannot answer a WebAuthn
  challenge. Both end up as `conn.assigns.current_user`; `:auth_method` records
  which one answered, since only a cookie needs CSRF protection.
  """

  import Plug.Conn
  import Phoenix.Controller

  alias Pinha.Accounts
  alias PinhaWeb.Failure

  @session_key "user_token"
  @realm "pinha"

  @doc "Assigns `:current_user` from the session cookie, or `nil`."
  def fetch_current_user(conn, _opts) do
    with token when is_binary(token) <- get_session(conn, @session_key),
         {:ok, user} <- Accounts.fetch_user_by_session_token(token) do
      conn |> assign(:current_user, user) |> assign(:auth_method, :session)
    else
      _ -> conn |> assign(:current_user, nil) |> assign(:auth_method, nil)
    end
  end

  @doc """
  Requires a signed-in browser.

  A signed-out browser is sent to the sign-in page; anything asking for JSON
  is told plainly, since redirecting a machine to a login form helps nobody.
  """
  def require_authenticated_user(conn, _opts) do
    if conn.assigns[:current_user] do
      conn
    else
      conn |> refuse("authentication required") |> halt()
    end
  end

  @doc """
  Requires a user, letting an API token stand in for a session.

  This is what management routes use: a browser form and a `curl` with a token
  both reach them.
  """
  def require_user_or_token(conn, opts) do
    if conn.assigns[:current_user] do
      conn
    else
      authenticate_with_token(conn, opts)
    end
  end

  @doc """
  Requires a user on the git transport routes.

  A refusal carries the Basic challenge, which is what makes `git` prompt for
  credentials and what lets a credential helper store the token afterwards.
  """
  def require_user_for_git(conn, opts) do
    if conn.assigns[:current_user] do
      conn
    else
      conn
      |> put_resp_header("www-authenticate", ~s(Basic realm="#{@realm}"))
      |> authenticate_with_token(opts)
    end
  end

  defp authenticate_with_token(conn, _opts) do
    with {email, secret} <- Plug.BasicAuth.parse_basic_auth(conn),
         {:ok, user} <- Accounts.fetch_user_by_api_token(email, secret) do
      conn |> assign(:current_user, user) |> assign(:auth_method, :token)
    else
      _ -> conn |> refuse("authentication required") |> halt()
    end
  end

  # Git negotiates no format at all, and a git client reads a body, not a
  # redirect: it retries with credentials once it sees the challenge.
  defp refuse(conn, message) do
    case get_format(conn) do
      "html" ->
        redirect(conn, to: "/signin")

      "json" ->
        Failure.send(conn, 401, message)

      _ ->
        conn
        |> put_resp_content_type("text/plain")
        |> send_resp(401, message <> "\n")
    end
  end

  @doc """
  Checks the CSRF token on cookie-authenticated writes only.

  A request that authenticated with an API token carries no ambient
  credential, so nothing can be forged from another origin on its behalf.
  """
  def maybe_protect_from_forgery(conn, opts) do
    if conn.assigns[:auth_method] == :token do
      conn
    else
      protect_from_forgery(conn, opts)
    end
  end

  @doc "Starts a session for `user`, replacing whatever session was there."
  def log_in_user(conn, user) do
    token = Accounts.create_session(user)

    conn
    |> renew_session()
    |> put_session(@session_key, token)
  end

  @doc "Ends the current session."
  def log_out_user(conn) do
    case get_session(conn, @session_key) do
      nil -> :ok
      token -> Accounts.delete_session(token)
    end

    renew_session(conn)
  end

  # A fresh session ID on sign-in and sign-out, so a session fixed by an
  # attacker before either never survives it.
  defp renew_session(conn) do
    delete_csrf_token()

    conn
    |> configure_session(renew: true)
    |> clear_session()
  end
end
