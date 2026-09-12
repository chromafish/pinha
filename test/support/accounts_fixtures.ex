defmodule Pinha.AccountsFixtures do
  @moduledoc """
  Users, passkeys, and tokens for tests.

  A passkey here is a row, not a ceremony: nothing in the suite can produce a
  real attestation without an authenticator, so the fixtures write the row the
  ceremony would have written.
  """

  alias Pinha.Accounts
  alias Pinha.Accounts.Credential

  @doc "A user holding one passkey. Pass `admin: true` for one who mints invites."
  def user_fixture(attrs \\ %{}) do
    email = Map.get(attrs, :email, "tester#{System.unique_integer([:positive])}@example.com")
    username = Map.get(attrs, :username, "tester#{System.unique_integer([:positive])}")

    {:ok, %{user: user}} =
      Accounts.register_user(
        %{
          username: username,
          email: email,
          handle: :crypto.strong_rand_bytes(32),
          admin: Map.get(attrs, :admin, false)
        },
        credential_attrs(Map.get(attrs, :label, "test key")),
        Map.get(attrs, :opts, [])
      )

    user
  end

  @doc "An invite minted by `admin`, returned in the clear as it is pasted."
  def invite_fixture(admin, label \\ "test invite") do
    {:ok, secret, _invite} = Accounts.create_invite(admin, label)
    secret
  end

  @doc "Another passkey on an existing user."
  def credential_fixture(user, label \\ "second key") do
    {:ok, credential} = Accounts.add_credential(user, credential_attrs(label))
    credential
  end

  @doc "An API token, returned in the clear as git would send it."
  def token_fixture(user, label \\ "test token") do
    {:ok, secret, _token} = Accounts.create_api_token(user, label)
    secret
  end

  @doc "The attributes a ceremony would have produced for one passkey."
  def credential_attrs(label \\ "test key") do
    %{
      credential_id: :crypto.strong_rand_bytes(32),
      public_key: Credential.encode_key(%{1 => 2, 3 => -7}),
      aaguid: <<0::128>>,
      sign_count: 0,
      label: label
    }
  end
end
