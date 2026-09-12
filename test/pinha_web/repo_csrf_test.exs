defmodule PinhaWeb.RepoCsrfTest do
  @moduledoc """
  Reproduction for the missing CSRF token on POST /repos.

  The repository list at GET / renders a `<form method="post" action="/repos">`.
  That form must carry a `_csrf_token` hidden input, otherwise a browser
  submission carries a session cookie but no token and the management pipeline
  (`Plug.CSRFProtection` via `maybe_protect_from_forgery`) raises
  `InvalidCSRFTokenError` (403 in prod).

  Token-authenticated `curl` requests skip CSRF by design (`auth_method == :token`),
  so they must succeed with no token.
  """

  use PinhaWeb.ConnCase, async: false

  alias Pinha.Accounts

  defp browser(conn),
    do: Plug.Conn.put_req_header(conn, "accept", "text/html,application/xhtml+xml")

  # Build a session that *does* enforce CSRF (Phoenix.ConnTest.build_conn skips it)
  defp csrf_session(user) do
    token = Accounts.create_session(user)

    # Generate a valid CSRF pair in the process dict, then pull it out
    masked = Plug.CSRFProtection.get_csrf_token()
    unmasked = Plug.CSRFProtection.dump_state()
    # Clean process dict so the next request\'s load_state is not polluted
    Process.delete(:plug_masked_csrf_token)
    Process.delete(:plug_unmasked_csrf_token)
    Process.delete(:plug_csrf_token_per_host)

    {%{"user_token" => token, "_csrf_token" => unmasked}, masked, unmasked}
  end

  defp do_request(session, method, path, params_or_body, headers \\ []) do
    base =
      Plug.Test.conn(method, path, params_or_body)
      |> Plug.Test.init_test_session(session)
      |> Map.put(:secret_key_base, PinhaWeb.Endpoint.config(:secret_key_base))
      |> Map.put(:host, "www.example.com")

    base =
      Enum.reduce(headers, base, fn {k, v}, acc -> Plug.Conn.put_req_header(acc, k, v) end)

    base =
      base
      |> Plug.Conn.put_private(:plug_skip_csrf_protection, false)
      |> Plug.Conn.put_private(:phoenix_recycled, false)

    PinhaWeb.Endpoint.call(base, PinhaWeb.Endpoint.init([]))
  end

  describe "the create-repo form" do
    test "carries a CSRF token so a browser submission is not 403", %{conn: conn, user: _user} do
      html = conn |> browser() |> get("/") |> html_response(200)

      # The form at POST /repos must contain a hidden _csrf_token, like every
      # other management form does (show.html.heex, settings).
      assert html =~ ~s(action="/repos")
      assert html =~ ~s(name="_csrf_token")

      # And the token should look like a Plug masked token (not empty)
      assert html =~ ~r/name="_csrf_token" value="[^"]+"/
    end
  end

  describe "POST /repos CSRF behaviour (session vs token)" do
    test "a session-authenticated browser POST without a CSRF token is 403" do
      user = Pinha.AccountsFixtures.user_fixture(%{admin: true})
      {session, _masked, _unmasked} = csrf_session(user)

      # No _csrf_token in params nor x-csrf-token header -> Plug raises (403 in prod)
      assert_raise Plug.CSRFProtection.InvalidCSRFTokenError, fn ->
        do_request(session, :post, "/repos", %{"name" => "no-csrf"})
      end
    end

    test "a session-authenticated browser POST with a CSRF token succeeds" do
      user = Pinha.AccountsFixtures.user_fixture(%{admin: true})
      {session, masked, _unmasked} = csrf_session(user)

      conn =
        do_request(session, :post, "/repos", %{
          "name" => "with-csrf-#{System.unique_integer([:positive])}",
          "_csrf_token" => masked
        })

      # Management pipeline accepts html and json; a form POST redirects to the new repo
      assert conn.status in [200, 201, 302]
      assert conn.status != 403
      # Redirect or JSON created
      location = Plug.Conn.get_resp_header(conn, "location") |> List.first()
      assert location =~ "/r/with-csrf" or conn.status == 201
    end

    test "a session-authenticated browser POST with x-csrf-token header succeeds" do
      user = Pinha.AccountsFixtures.user_fixture(%{admin: true})
      {session, masked, _unmasked} = csrf_session(user)

      conn =
        do_request(
          session,
          :post,
          "/repos",
          %{"name" => "header-csrf-#{System.unique_integer([:positive])}"},
          [
            {"x-csrf-token", masked}
          ]
        )

      assert conn.status in [200, 201, 302]
      assert conn.status != 403
    end

    test "a token-authenticated API POST skips CSRF and succeeds with no token", %{user: user} do
      secret = Pinha.AccountsFixtures.token_fixture(user)

      # Use the real Endpoint via a token request that has no session and no CSRF
      conn =
        Plug.Test.conn(:post, "/repos", %{
          "name" => "by-token-#{System.unique_integer([:positive])}"
        })
        |> Plug.Conn.put_req_header(
          "authorization",
          "Basic " <> Base.encode64("#{user.email}:#{secret}")
        )
        |> Plug.Conn.put_req_header("accept", "application/json")
        |> Map.put(:secret_key_base, PinhaWeb.Endpoint.config(:secret_key_base))
        |> Map.put(:host, "www.example.com")
        |> Plug.Conn.put_private(:plug_skip_csrf_protection, false)
        |> PinhaWeb.Endpoint.call(PinhaWeb.Endpoint.init([]))

      assert conn.status == 201
    end
  end
end
