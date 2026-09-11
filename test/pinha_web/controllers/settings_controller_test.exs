defmodule PinhaWeb.SettingsControllerTest do
  use PinhaWeb.ConnCase, async: false

  alias Pinha.Accounts

  describe "GET /settings" do
    test "lists the passkeys and says why a token exists", %{conn: conn, user: user} do
      html = conn |> get("/settings") |> html_response(200)

      assert html =~ "test key"
      assert html =~ user.email
      assert html =~ "No tokens."
    end

    test "is refused to a signed-out browser" do
      assert build_conn() |> get("/settings") |> redirected_to() == "/signin"
    end
  end

  describe "POST /settings/tokens" do
    test "shows the token once, and never again", %{conn: conn, user: user} do
      html = conn |> post("/settings/tokens", %{"label" => "laptop"}) |> html_response(200)

      [secret] = Regex.run(~r/pinha_[A-Za-z0-9_-]+/, html)
      assert {:ok, found} = Accounts.fetch_user_by_api_token(user.email, secret)
      assert found.id == user.id

      refute signed_in_conn() |> get("/settings") |> html_response(200) =~ secret
    end

    test "an expiry in days is honoured", %{conn: conn, user: user} do
      conn |> post("/settings/tokens", %{"label" => "short", "expires_in" => "7"})

      [token] = Accounts.list_api_tokens(user)
      assert DateTime.diff(token.expires_at, DateTime.utc_now(), :day) in 6..7
    end
  end

  describe "DELETE /settings/tokens/:id" do
    test "revokes the token", %{conn: conn, user: user} do
      secret = token_fixture(user)
      [token] = Accounts.list_api_tokens(user)

      assert conn |> delete("/settings/tokens/#{token.id}") |> redirected_to() == "/settings"
      assert :error = Accounts.fetch_user_by_api_token(user.email, secret)
    end

    test "another user's token is not reachable", %{conn: conn} do
      other = user_fixture()
      token_fixture(other)
      [token] = Accounts.list_api_tokens(other)

      assert conn |> delete("/settings/tokens/#{token.id}") |> response(404)
      assert [_] = Accounts.list_api_tokens(other)
    end
  end

  describe "DELETE /settings/passkeys/:id" do
    test "refuses to remove the only passkey", %{conn: conn, user: user} do
      [only] = Accounts.list_credentials(user)

      assert conn |> delete("/settings/passkeys/#{only.id}") |> response(409) =~ "only passkey"
      assert [_] = Accounts.list_credentials(user)
    end

    test "removes one when another remains", %{conn: conn, user: user} do
      [only] = Accounts.list_credentials(user)
      credential_fixture(user)

      assert conn |> delete("/settings/passkeys/#{only.id}") |> redirected_to() == "/settings"
      assert [remaining] = Accounts.list_credentials(user)
      assert remaining.label == "second key"
    end
  end

  describe "POST /settings/passkeys/challenge" do
    test "excludes the passkeys already registered", %{conn: conn, user: user} do
      [existing] = Accounts.list_credentials(user)

      conn =
        conn
        |> put_req_header("accept", "application/json")
        |> post("/settings/passkeys/challenge", %{"label" => "phone"})

      assert %{"publicKey" => options} = json_response(conn, 200)
      assert [%{"id" => id}] = options["excludeCredentials"]
      assert Base.url_decode64!(id, padding: false) == existing.credential_id
    end

    test "is refused to a signed-out browser" do
      conn =
        build_conn()
        |> put_req_header("accept", "application/json")
        |> post("/settings/passkeys/challenge", %{})

      assert json_response(conn, 401)
    end
  end
end
