defmodule PinhaWeb.SettingsControllerTest do
  use PinhaWeb.ConnCase, async: false

  alias Pinha.Accounts

  describe "GET /settings" do
    test "lists the passkeys and says why a token exists", %{conn: conn, user: user} do
      html = conn |> get("/settings") |> html_response(200)

      assert html =~ "test key"
      assert html =~ user.email
      assert html =~ "No tokens."
      assert html =~ ~s(id="settings" class="settings")
      assert html =~ ~s(class="table settings-table")
      assert html =~ ~s(data-label="Action")
      assert html =~ ~s(id="mint-token")
    end

    test "is refused to a signed-out browser" do
      assert build_conn() |> get("/settings") |> redirected_to() == "/signin"
    end
  end

  describe "POST /settings/invites" do
    test "shows the invite once, and never again", %{conn: conn} do
      html = conn |> post("/settings/invites", %{"label" => "alice"}) |> html_response(200)

      [secret] = Regex.run(~r/pinha_invite_[A-Za-z0-9_-]+/, html)
      assert {:ok, invite} = Accounts.fetch_usable_invite(secret)
      assert invite.label == "alice"

      refute signed_in_conn() |> get("/settings") |> html_response(200) =~ secret
    end

    test "is refused to a user who is not an admin" do
      conn = log_in_user(build_conn(), user_fixture())

      assert conn |> post("/settings/invites", %{"label" => "sneaky"}) |> response(403)

      assert Accounts.list_invites() == []
    end
  end

  describe "POST /settings/ssh-keys" do
    test "registers a pasted key and shows its fingerprint", %{conn: conn, user: user} do
      public = generate_key()

      assert conn
             |> post("/settings/ssh-keys", %{"key" => public, "label" => "laptop"})
             |> redirected_to() == "/settings"

      assert [key] = Accounts.list_ssh_keys(user)
      assert key.label == "laptop"

      html = signed_in_conn() |> get("/settings") |> html_response(200)
      assert html =~ "laptop"
      assert html =~ "SHA256:"
      assert html =~ "ssh://git@"
    end

    test "says what is wrong with a key it will not take", %{conn: conn, user: user} do
      assert conn |> post("/settings/ssh-keys", %{"key" => "not a key"}) |> response(422) =~
               "does not look like an SSH public key"

      assert Accounts.list_ssh_keys(user) == []
    end

    test "refuses a key already registered to someone", %{conn: conn} do
      public = generate_key()
      {:ok, _} = Accounts.add_ssh_key(user_fixture(), public)

      assert conn |> post("/settings/ssh-keys", %{"key" => public}) |> response(409) =~
               "already registered"
    end
  end

  describe "DELETE /settings/ssh-keys/:id" do
    test "revokes a key", %{conn: conn, user: user} do
      {:ok, key} = Accounts.add_ssh_key(user, generate_key())

      assert conn |> delete("/settings/ssh-keys/#{key.id}") |> redirected_to() == "/settings"
      assert Accounts.list_ssh_keys(user) == []
    end

    test "leaves someone else's key alone", %{conn: conn} do
      {:ok, key} = Accounts.add_ssh_key(user_fixture(), generate_key())

      assert conn |> delete("/settings/ssh-keys/#{key.id}") |> response(404)
    end
  end

  describe "DELETE /settings/invites/:id" do
    test "revokes one that has not been used", %{conn: conn, user: admin} do
      secret = invite_fixture(admin)
      {:ok, invite} = Accounts.fetch_usable_invite(secret)

      assert conn |> delete("/settings/invites/#{invite.id}") |> redirected_to() == "/settings"
      assert :error = Accounts.fetch_usable_invite(secret)
    end

    test "is refused to a user who is not an admin", %{user: admin} do
      secret = invite_fixture(admin)
      {:ok, invite} = Accounts.fetch_usable_invite(secret)
      conn = log_in_user(build_conn(), user_fixture())

      assert conn |> delete("/settings/invites/#{invite.id}") |> response(403)

      assert {:ok, _} = Accounts.fetch_usable_invite(secret)
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

  defp generate_key do
    path =
      Path.join(System.tmp_dir!(), "pinha-settings-key-#{System.unique_integer([:positive])}")

    {_out, 0} = System.cmd("ssh-keygen", ["-q", "-t", "ed25519", "-N", "", "-f", path])
    on_exit(fn -> Enum.each([path, path <> ".pub"], &File.rm/1) end)
    File.read!(path <> ".pub")
  end
end
