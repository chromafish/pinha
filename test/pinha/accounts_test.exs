defmodule Pinha.AccountsTest do
  use Pinha.DataCase, async: false

  alias Pinha.Accounts.Registration
  alias Pinha.Accounts.User

  describe "invites" do
    test "one invite admits one registration and is spent by it" do
      admin = user_fixture(%{admin: true})
      secret = invite_fixture(admin)

      assert {:ok, invite} = Accounts.fetch_usable_invite(secret)

      assert {:ok, %{user: user}} =
               Accounts.register_user(
                 %{
                   username: "invited",
                   email: "invited@example.com",
                   handle: :crypto.strong_rand_bytes(32)
                 },
                 credential_attrs("their key"),
                 invite: invite
               )

      refute user.admin
      assert :error = Accounts.fetch_usable_invite(secret)

      spent = Enum.find(Accounts.list_invites(), &(&1.id == invite.id))
      assert spent.consumed_by.id == user.id
    end

    test "the same invite cannot admit a second registration" do
      admin = user_fixture(%{admin: true})
      secret = invite_fixture(admin)
      {:ok, invite} = Accounts.fetch_usable_invite(secret)

      assert {:ok, _} =
               Accounts.register_user(
                 %{
                   username: "first",
                   email: "first@example.com",
                   handle: :crypto.strong_rand_bytes(32)
                 },
                 credential_attrs("first key"),
                 invite: invite
               )

      assert {:error, :invite, :invite_spent} =
               Accounts.register_user(
                 %{
                   username: "second",
                   email: "second@example.com",
                   handle: :crypto.strong_rand_bytes(32)
                 },
                 credential_attrs("second key"),
                 invite: invite
               )

      assert :error = Accounts.fetch_user_by_email("second@example.com")
    end

    test "an expired invite admits nothing" do
      admin = user_fixture(%{admin: true})
      secret = invite_fixture(admin)
      {:ok, invite} = Accounts.fetch_usable_invite(secret)

      invite
      |> Ecto.Changeset.change(
        expires_at: DateTime.utc_now() |> DateTime.add(-1, :second) |> DateTime.truncate(:second)
      )
      |> Pinha.Repo.update!()

      assert :error = Accounts.fetch_usable_invite(secret)
      assert :error = Accounts.fetch_usable_invite_by_id(invite.id)
    end

    test "revoking one takes it out of circulation" do
      admin = user_fixture(%{admin: true})
      secret = invite_fixture(admin)
      {:ok, invite} = Accounts.fetch_usable_invite(secret)

      assert :ok = Accounts.delete_invite(invite.id)
      assert :error = Accounts.fetch_usable_invite(secret)
      assert {:error, :not_found} = Accounts.delete_invite(invite.id)
    end
  end

  describe "claiming the server" do
    test "the claim token admits one registration and then is spent" do
      token = claim_token()

      assert Registration.claim?(token)
      refute Registration.claim?("not the token")

      assert Registration.consume_claim(token)
      refute Registration.claim?(token)
      refute Registration.consume_claim(token)
    end

    test "minting again replaces the outstanding token" do
      first = claim_token()
      second = claim_token()

      refute Registration.claim?(first)
      assert Registration.claim?(second)
    end
  end

  describe "users" do
    test "an email is claimed once" do
      user = user_fixture()

      assert {:error, :user, changeset} =
               Accounts.register_user(
                 %{
                   username: "other#{System.unique_integer([:positive])}",
                   email: String.upcase(user.email),
                   handle: :crypto.strong_rand_bytes(32)
                 },
                 %{credential_id: "x", public_key: "y", label: "k"}
               )

      assert "has already been taken" in errors_on(changeset).email
    end

    # The authenticator was handed this handle before the row existed and
    # replays it on every assertion, so a registration that mints its own
    # instead stores a user no passkey can name and sign-in 403s forever.
    test "keeps the handle the registration challenge handed the authenticator" do
      handle = User.generate_handle()

      assert {:ok, %{user: user}} =
               Accounts.register_user(
                 %{username: "handled", email: "handled@example.com", handle: handle},
                 credential_attrs("their key")
               )

      assert user.handle == handle
      assert {:ok, found} = Accounts.fetch_user_by_handle(handle)
      assert found.id == user.id
    end

    test "refuses a registration with no handle, or one of the wrong size" do
      assert {:error, :user, changeset} =
               Accounts.register_user(
                 %{username: "nohandle", email: "nohandle@example.com"},
                 credential_attrs("their key")
               )

      assert "can't be blank" in errors_on(changeset).handle

      assert {:error, :user, short} =
               Accounts.register_user(
                 %{
                   username: "short",
                   email: "short@example.com",
                   handle: <<1, 2, 3>>
                 },
                 credential_attrs("their key")
               )

      assert "must be 32 bytes" in errors_on(short).handle
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

  describe "ssh keys" do
    setup do
      dir = Path.join(System.tmp_dir!(), "pinha-keys-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf(dir) end)
      [dir: dir]
    end

    test "registers a pasted key and finds the user by fingerprint", %{dir: dir} do
      user = user_fixture()
      {public, _path} = generate_key(dir, "ed25519")

      assert {:ok, key} = Accounts.add_ssh_key(user, public)
      assert key.algorithm == "ssh-ed25519"
      assert byte_size(key.fingerprint) == 32
      assert key.label =~ "@"

      assert [listed] = Accounts.list_ssh_keys(user)
      assert listed.id == key.id

      assert {:ok, found} = Accounts.fetch_user_by_ssh_fingerprint(key.fingerprint)
      assert found.id == user.id
    end

    test "takes the label from the form when one is given", %{dir: dir} do
      user = user_fixture()
      {public, _path} = generate_key(dir, "ed25519")

      assert {:ok, key} = Accounts.add_ssh_key(user, public, "laptop")
      assert key.label == "laptop"
    end

    test "one key belongs to one person", %{dir: dir} do
      {public, _path} = generate_key(dir, "ed25519")
      {:ok, _} = Accounts.add_ssh_key(user_fixture(), public)

      assert Accounts.add_ssh_key(user_fixture(), public) == {:error, :already_registered}
    end

    test "refuses what is not a key, and an RSA key too small to be one", %{dir: dir} do
      user = user_fixture()
      {weak, _path} = generate_key(dir, "rsa", ["-b", "1024"])

      assert Accounts.add_ssh_key(user, "hello") == {:error, :unreadable}
      assert Accounts.add_ssh_key(user, "") == {:error, :unreadable}
      assert Accounts.add_ssh_key(user, weak) == {:error, :weak_key}
    end

    test "accepts the key types worth accepting", %{dir: dir} do
      user = user_fixture()

      for {type, args, algorithm} <- [
            {"ed25519", [], "ssh-ed25519"},
            {"ecdsa", ["-b", "256"], "ecdsa-sha2-nistp256"},
            {"rsa", ["-b", "2048"], "ssh-rsa"}
          ] do
        {public, _path} = generate_key(dir, type, args)
        assert {:ok, key} = Accounts.add_ssh_key(user, public)
        assert key.algorithm == algorithm
      end
    end

    test "records use at most once an hour", %{dir: dir} do
      user = user_fixture()
      {public, _path} = generate_key(dir, "ed25519")
      {:ok, key} = Accounts.add_ssh_key(user, public)

      assert {:ok, _} = Accounts.fetch_user_by_ssh_fingerprint(key.fingerprint)
      [touched] = Accounts.list_ssh_keys(user)
      assert touched.last_used_at

      assert {:ok, _} = Accounts.fetch_user_by_ssh_fingerprint(key.fingerprint)
      [again] = Accounts.list_ssh_keys(user)
      assert again.last_used_at == touched.last_used_at
    end

    test "revoking a key stops the next connection", %{dir: dir} do
      user = user_fixture()
      {public, _path} = generate_key(dir, "ed25519")
      {:ok, key} = Accounts.add_ssh_key(user, public)

      assert Accounts.delete_ssh_key(user_fixture(), key.id) == {:error, :not_found}
      assert Accounts.delete_ssh_key(user, key.id) == :ok
      assert Accounts.list_ssh_keys(user) == []
      assert Accounts.fetch_user_by_ssh_fingerprint(key.fingerprint) == :error
    end

    test "deleting a user takes their keys with them", %{dir: dir} do
      user = user_fixture()
      {public, _path} = generate_key(dir, "ed25519")
      {:ok, key} = Accounts.add_ssh_key(user, public)

      Pinha.Repo.delete!(user)

      assert Accounts.fetch_user_by_ssh_fingerprint(key.fingerprint) == :error
    end
  end

  describe "uid" do
    test "is opaque, unique, and outlives an email" do
      first = user_fixture()
      second = user_fixture()

      assert first.uid =~ ~r/\Au_[a-z2-7]{26}\z/
      refute first.uid == second.uid

      assert {:ok, found} = Accounts.fetch_user_by_uid(first.uid)
      assert found.id == first.id

      renamed =
        first
        |> Ecto.Changeset.change(email: "moved#{System.unique_integer([:positive])}@example.com")
        |> Pinha.Repo.update!()

      assert renamed.uid == first.uid
      assert Accounts.fetch_user_by_uid("u_nope") == :error
    end
  end

  describe "recovery" do
    test "an authorization admits one ceremony and then is spent" do
      user = user_fixture()

      refute Registration.authorized?(user.email)

      assert :ok = Registration.authorize(String.upcase(user.email))
      assert Registration.authorized?(user.email)

      assert Registration.consume(user.email)
      refute Registration.authorized?(user.email)
      refute Registration.consume(user.email)
    end
  end

  defp generate_key(dir, type, args \\ []) do
    path = Path.join(dir, "#{type}-#{System.unique_integer([:positive])}")
    {_out, 0} = System.cmd("ssh-keygen", ["-q", "-t", type, "-N", "", "-f", path] ++ args)
    {File.read!(path <> ".pub"), path}
  end

  defp claim_token do
    Registration.claim() |> String.split("claim=") |> List.last()
  end

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), "") |> to_string()
      end)
    end)
  end
end
