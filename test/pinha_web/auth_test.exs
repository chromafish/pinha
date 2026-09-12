defmodule PinhaWeb.AuthTest do
  use PinhaWeb.ConnCase, async: false

  alias Pinha.Accounts
  alias Pinha.Accounts.Registration

  # The repository list answers machines as well as browsers, so which one is
  # asking decides whether a refusal is a redirect or a 401.
  defp browser(conn), do: put_req_header(conn, "accept", "text/html,application/xhtml+xml")

  describe "a signed-out request" do
    test "is sent to the sign-in page by a browser route" do
      assert build_conn() |> browser() |> get("/") |> redirected_to() == "/signin"
    end

    test "is refused with 401 when it asks for JSON" do
      conn =
        build_conn()
        |> put_req_header("accept", "application/json")
        |> get("/")

      assert %{"error" => _} = json_response(conn, 401)
    end

    test "still reaches the sign-in and sign-up pages" do
      assert build_conn() |> get("/signin") |> html_response(200) =~ "Use a passkey"
      assert build_conn() |> get("/signup") |> html_response(200) =~ "Sign in"
    end

    test "is offered the form on a server that has no users yet" do
      Pinha.Repo.delete_all(Pinha.Accounts.User)

      html = build_conn() |> get("/signup") |> html_response(200)
      assert html =~ "Claim this server"
      assert html =~ "Create passkey"
    end
  end

  describe "a signed-in request" do
    test "reads the repository list", %{conn: conn} do
      assert conn |> browser() |> get("/") |> html_response(200) =~ "Repositories"
    end

    test "is sent away from the sign-in page", %{conn: conn} do
      assert conn |> get("/signin") |> redirected_to() == "/"
    end

    test "carries the user into the widelog", %{conn: conn, user: user} do
      conn = get(conn, "/")
      line = PinhaWeb.Observability.line(conn, PinhaWeb.Observability.route(conn), 1.0)

      assert line.user == user.id
    end
  end

  describe "sign out" do
    test "ends the session it was made with", %{conn: conn} do
      token = get_session(conn, "user_token")
      assert conn |> delete("/signout") |> redirected_to() == "/signin"
      assert :error = Accounts.fetch_user_by_session_token(token)
    end
  end

  describe "git transport" do
    setup do
      create_repo!("demo")
      :ok
    end

    test "challenges an anonymous client so git knows to send credentials" do
      conn = build_conn() |> get("/demo.git/info/refs?service=git-upload-pack")

      assert response(conn, 401)
      assert get_resp_header(conn, "www-authenticate") == [~s(Basic realm="pinha")]
    end

    test "accepts a token over HTTP Basic", %{user: user} do
      secret = token_fixture(user)

      conn =
        build_conn()
        |> put_req_header("authorization", basic(user.email, secret))
        |> get("/demo.git/info/refs?service=git-upload-pack")

      assert response(conn, 200) =~ "service=git-upload-pack"
    end

    test "refuses a token that is not the named user's", %{user: user} do
      other = user_fixture()
      secret = token_fixture(other)

      conn =
        build_conn()
        |> put_req_header("authorization", basic(user.email, secret))
        |> get("/demo.git/info/refs?service=git-upload-pack")

      assert response(conn, 401)
    end
  end

  describe "management routes" do
    test "take a token instead of a session, so curl works", %{user: user} do
      secret = token_fixture(user)

      conn =
        build_conn()
        |> put_req_header("authorization", basic(user.email, secret))
        |> put_req_header("accept", "application/json")
        |> post("/repos", %{"name" => "by-token"})

      assert %{"name" => "by-token"} = json_response(conn, 201)
    end
  end

  describe "sign-up" do
    test "asks for an invite once the server has a user", %{user: _user} do
      html = build_conn() |> get("/signup") |> html_response(200)

      assert html =~ "Registration takes an invite"
      assert html =~ "pinha_invite_"
    end

    test "refuses a challenge that carries no invite" do
      conn =
        build_conn()
        |> put_req_header("accept", "application/json")
        |> post("/signup/challenge", %{"email" => "someone@example.com", "label" => "k"})

      assert %{"error" => "that invite is spent, expired, or was never minted"} =
               json_response(conn, 403)
    end

    test "hands out a challenge to whoever pastes an invite", %{user: admin} do
      secret = invite_fixture(admin)

      conn =
        build_conn()
        |> put_req_header("accept", "application/json")
        |> post("/signup/challenge", %{
          "email" => "invited@example.com",
          "label" => "k",
          "invite" => secret
        })

      assert %{"publicKey" => %{"user" => %{"name" => "invited@example.com"}}} =
               json_response(conn, 200)
    end

    test "refuses an invite that has already been spent", %{user: admin} do
      secret = invite_fixture(admin)
      {:ok, invite} = Accounts.fetch_usable_invite(secret)

      {:ok, _} =
        Accounts.register_user(
          %{email: "first@example.com", handle: :crypto.strong_rand_bytes(32)},
          credential_attrs("first key"),
          invite: invite
        )

      conn =
        build_conn()
        |> put_req_header("accept", "application/json")
        |> post("/signup/challenge", %{
          "email" => "second@example.com",
          "label" => "k",
          "invite" => secret
        })

      assert json_response(conn, 403)
    end

    test "offers a challenge to a recovering user the operator authorized", %{user: user} do
      assert :ok = Registration.authorize(user.email)

      conn =
        build_conn()
        |> put_req_header("accept", "application/json")
        |> post("/signup/challenge", %{"email" => user.email, "label" => "replacement"})

      assert %{"publicKey" => %{"challenge" => _, "user" => %{"name" => name}}} =
               json_response(conn, 200)

      assert name == user.email
    end

    test "asks a fresh server for the claim token, and refuses the wrong one" do
      Pinha.Repo.delete_all(Pinha.Accounts.User)
      Registration.claim()

      html = build_conn() |> get("/signup") |> html_response(200)
      assert html =~ "Claim token"

      conn =
        build_conn()
        |> put_req_header("accept", "application/json")
        |> post("/signup/challenge", %{
          "email" => "operator@example.com",
          "label" => "k",
          "claim" => "not the token"
        })

      assert %{"error" => error} = json_response(conn, 403)
      assert error =~ "claim token"
    end

    test "hands out a challenge to whoever holds the claim token" do
      Pinha.Repo.delete_all(Pinha.Accounts.User)
      token = Registration.claim() |> String.split("claim=") |> List.last()

      conn =
        build_conn()
        |> put_req_header("accept", "application/json")
        |> post("/signup/challenge", %{
          "email" => "operator@example.com",
          "label" => "k",
          "claim" => token
        })

      assert %{"publicKey" => %{"user" => %{"name" => "operator@example.com"}}} =
               json_response(conn, 200)
    end

    test "refuses a challenge for an existing user with no authorization", %{user: user} do
      conn =
        build_conn()
        |> put_req_header("accept", "application/json")
        |> post("/signup/challenge", %{"email" => user.email, "label" => "replacement"})

      assert json_response(conn, 403)
    end
  end

  describe "sign-in" do
    test "hands out a challenge that names no credentials, so any passkey answers" do
      conn =
        build_conn()
        |> put_req_header("accept", "application/json")
        |> post("/signin/challenge", %{})

      assert %{"publicKey" => options} = json_response(conn, 200)
      assert options["challenge"]
      refute Map.has_key?(options, "allowCredentials")
    end

    test "refuses an answer to a challenge that was never issued" do
      conn =
        build_conn()
        |> put_req_header("accept", "application/json")
        |> post("/signin", %{"id" => "x", "userHandle" => "y"})

      assert json_response(conn, 403)
    end
  end

  defp basic(email, secret), do: "Basic " <> Base.encode64("#{email}:#{secret}")
end
