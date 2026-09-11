defmodule Pinha.AccountsTest do
  use Pinha.DataCase, async: false

  alias Pinha.Accounts.Recovery

  describe "sign-up gating" do
    test "the first user claims a fresh server, and the next one is refused" do
      assert Accounts.signup_open?()

      user_fixture()

      refute Accounts.signup_open?()
    end

    test "the operator can leave sign-up open" do
      user_fixture()
      Application.put_env(:pinha, :signup_open, true)
      on_exit(fn -> Application.delete_env(:pinha, :signup_open) end)

      assert Accounts.signup_open?()
    end

    test "an email is claimed once" do
      user = user_fixture()

      assert {:error, :user, changeset} =
               Accounts.register_user(
                 %{email: String.upcase(user.email), handle: :crypto.strong_rand_bytes(32)},
                 %{credential_id: "x", public_key: "y", label: "k"}
               )

      assert "has already been taken" in errors_on(changeset).email
    end
  end

  describe "sessions" do
    test "a token identifies its user until it is deleted" do
      user = user_fixture()
      token = Accounts.create_session(user)

      assert {:ok, found} = Accounts.fetch_user_by_session_token(token)
      assert found.id == user.id

      assert :ok = Accounts.delete_session(token)
      assert :error = Accounts.fetch_user_by_session_token(token)
    end

    test "an unknown token identifies nobody" do
      assert :error = Accounts.fetch_user_by_session_token(:crypto.strong_rand_bytes(32))
    end
  end

  describe "api tokens" do
    test "a token authenticates with its owner's email" do
      user = user_fixture()
      secret = token_fixture(user)

      assert {:ok, found} = Accounts.fetch_user_by_api_token(user.email, secret)
      assert found.id == user.id
    end

    test "a token presented with another user's email is refused" do
      user = user_fixture()
      other = user_fixture()
      secret = token_fixture(user)

      assert :error = Accounts.fetch_user_by_api_token(other.email, secret)
    end

    test "an expired token is refused" do
      user = user_fixture()
      past = DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.truncate(:second)
      {:ok, secret, _token} = Accounts.create_api_token(user, "old", past)

      assert :error = Accounts.fetch_user_by_api_token(user.email, secret)
    end

    test "a revoked token stops working" do
      user = user_fixture()
      secret = token_fixture(user)
      [token] = Accounts.list_api_tokens(user)

      assert :ok = Accounts.delete_api_token(user, token.id)
      assert :error = Accounts.fetch_user_by_api_token(user.email, secret)
    end

    test "the token is only readable when it is minted" do
      user = user_fixture()
      {:ok, secret, token} = Accounts.create_api_token(user, "laptop")

      assert String.starts_with?(secret, "pinha_")
      assert token.token_hash == :crypto.hash(:sha256, secret)
      refute token.token_hash == secret
    end
  end

  describe "passkeys" do
    test "a signature counter that fails to advance is refused" do
      user = user_fixture()
      [credential] = Accounts.list_credentials(user)

      assert {:ok, _} = Accounts.record_authentication(user, credential.credential_id, 5)
      assert {:ok, _} = Accounts.record_authentication(user, credential.credential_id, 6)

      assert {:error, :counter_did_not_advance} =
               Accounts.record_authentication(user, credential.credential_id, 6)
    end

    test "an authenticator that never counts is allowed to stay at zero" do
      user = user_fixture()
      [credential] = Accounts.list_credentials(user)

      assert {:ok, _} = Accounts.record_authentication(user, credential.credential_id, 0)
      assert {:ok, _} = Accounts.record_authentication(user, credential.credential_id, 0)
    end

    test "another user's credential is not accepted" do
      user = user_fixture()
      other = user_fixture()
      [credential] = Accounts.list_credentials(other)

      assert {:error, :unknown_credential} =
               Accounts.record_authentication(user, credential.credential_id, 1)
    end

    test "the last passkey cannot be removed" do
      user = user_fixture()
      [only] = Accounts.list_credentials(user)

      assert {:error, :last_credential} = Accounts.delete_credential(user, only.id)

      credential_fixture(user)
      assert :ok = Accounts.delete_credential(user, only.id)
    end
  end

  describe "recovery" do
    test "an authorization admits one ceremony and then is spent" do
      user = user_fixture()

      refute Recovery.authorized?(user.email)

      assert :ok = Recovery.authorize(String.upcase(user.email))
      assert Recovery.authorized?(user.email)

      assert Recovery.consume(user.email)
      refute Recovery.authorized?(user.email)
      refute Recovery.consume(user.email)
    end
  end

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), "") |> to_string()
      end)
    end)
  end
end
