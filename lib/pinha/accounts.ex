defmodule Pinha.Accounts do
  @moduledoc """
  Users, their passkeys, browser sessions, and what git authenticates with:
  tokens over HTTP and public keys over SSH.

  Every secret this module hands out is returned once, in the clear, and kept
  only as a SHA-256: a session token, an API token. Lookups hash the presented
  value and read an index, so verifying a token on each git request is one
  indexed read rather than a key derivation. An SSH key is not a secret, but
  it is stored the same way and looked up by the same kind of read, on the
  SHA-256 fingerprint.
  """

  import Ecto.Query

  alias Ecto.Multi
  alias Pinha.Accounts.ApiToken
  alias Pinha.Accounts.Credential
  alias Pinha.Accounts.Invite
  alias Pinha.Accounts.Session
  alias Pinha.Accounts.SshKey
  alias Pinha.Accounts.User
  alias Pinha.Repo

  @session_validity_days 60
  @token_bytes 32
  @token_prefix "pinha_"
  @invite_prefix "pinha_invite_"
  @invite_validity_days 7
  # Reading a token is a read. Recording that it was used is a write, so it
  # happens at most once an hour per row rather than once per request.
  @touch_after_seconds 3600

  ## Users

  @doc "How many users exist."
  @spec count_users() :: non_neg_integer()
  def count_users, do: Repo.aggregate(User, :count)

  @doc "Fetches a user by the WebAuthn handle an authenticator returned."
  @spec fetch_user_by_handle(binary()) :: {:ok, User.t()} | :error
  def fetch_user_by_handle(handle) when is_binary(handle) do
    case Repo.get_by(User, handle: handle) do
      nil -> :error
      user -> {:ok, user}
    end
  end

  @doc """
  Fetches a user by the `uid` something outside the database recorded.

  Repository ownership is the caller: a repo names its owner in its own git
  config, and this turns that name back into a user.
  """
  @spec fetch_user_by_uid(String.t() | nil) :: {:ok, User.t()} | :error
  def fetch_user_by_uid(uid) when is_binary(uid) do
    case Repo.get_by(User, uid: uid) do
      nil -> :error
      user -> {:ok, user}
    end
  end

  def fetch_user_by_uid(_), do: :error

  @doc "Every user, by username, for the owner picker."
  @spec list_users() :: [User.t()]
  def list_users, do: Repo.all(from(u in User, order_by: u.username))

  @doc "Fetches a user by username, case-sensitive, stored as supplied."
  @spec fetch_user_by_username(String.t()) :: {:ok, User.t()} | :error
  def fetch_user_by_username(username) when is_binary(username) do
    case Repo.get_by(User, username: username) do
      nil -> :error
      user -> {:ok, user}
    end
  end

  def fetch_user_by_username(_), do: :error

  @doc "Builds a changeset for updating a username, for forms."
  @spec change_username(User.t(), map()) :: Ecto.Changeset.t()
  def change_username(%User{} = user, attrs \\ %{}) do
    User.username_changeset(user, attrs)
  end

  @doc """
  Updates a user's username.

  Validates the same rules as signup: required, unique, at most 64 chars,
  not blank after trim, stored as supplied and case-sensitive.
  """
  @spec update_username(User.t(), map()) :: {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def update_username(%User{} = user, attrs) do
    user
    |> User.username_changeset(attrs)
    |> Repo.update()
  end

  @doc false
  @spec update_user_username(User.t(), map()) :: {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def update_user_username(%User{} = user, attrs), do: update_username(user, attrs)

  @doc "Fetches a user by email, however it was capitalized."
  @spec fetch_user_by_email(String.t()) :: {:ok, User.t()} | :error
  def fetch_user_by_email(email) when is_binary(email) do
    case Repo.get_by(User, email: email |> String.trim() |> String.downcase()) do
      nil -> :error
      user -> {:ok, user}
    end
  end

  @doc """
  Creates a user and their first passkey in one transaction.

  A half-registered user with no passkey could never sign in, so neither row
  lands without the other. An `:invite` in `opts` is spent in the same
  transaction, so two people holding one invite cannot both register.
  """
  @spec register_user(map(), map(), keyword()) ::
          {:ok, %{user: User.t(), credential: Credential.t()}}
          | {:error, atom(), Ecto.Changeset.t() | :invite_spent}
  def register_user(user_attrs, credential_attrs, opts \\ []) do
    Multi.new()
    |> Multi.insert(:user, User.changeset(%User{}, user_attrs))
    |> Multi.insert(:credential, fn %{user: user} ->
      Credential.changeset(%Credential{}, Map.put(credential_attrs, :user_id, user.id))
    end)
    |> Multi.run(:invite, fn repo, %{user: user} ->
      spend_invite(repo, Keyword.get(opts, :invite), user)
    end)
    |> Repo.transaction()
    |> case do
      {:ok, result} -> {:ok, result}
      {:error, step, reason, _changes} -> {:error, step, reason}
    end
  end

  ## Invites

  @doc """
  Mints an invite and returns it in the clear, the only time it is readable.

  It expires in a week and admits one registration. Handing it over is the
  admin's problem: the server delivers no mail.
  """
  @spec create_invite(User.t(), String.t()) ::
          {:ok, String.t(), Invite.t()} | {:error, Ecto.Changeset.t()}
  def create_invite(%User{} = admin, label) do
    secret =
      @invite_prefix <> Base.url_encode64(:crypto.strong_rand_bytes(@token_bytes), padding: false)

    attrs = %{
      token_hash: hash(secret),
      label: label,
      created_by_user_id: admin.id,
      expires_at: DateTime.add(now(), @invite_validity_days * 24 * 3600, :second)
    }

    case %Invite{} |> Invite.changeset(attrs) |> Repo.insert() do
      {:ok, invite} -> {:ok, secret, invite}
      {:error, changeset} -> {:error, changeset}
    end
  end

  @doc "Every invite, newest first, with whoever minted and spent it."
  @spec list_invites() :: [Invite.t()]
  def list_invites do
    Repo.all(from(i in Invite, order_by: [desc: i.id], preload: [:created_by, :consumed_by]))
  end

  @doc "The invite a registration presented, if it is neither spent nor expired."
  @spec fetch_usable_invite(String.t()) :: {:ok, Invite.t()} | :error
  def fetch_usable_invite(secret) when is_binary(secret) do
    one_usable_invite(from(i in Invite, where: i.token_hash == ^hash(secret)))
  end

  @doc "The same, by row id, for a ceremony already under way."
  @spec fetch_usable_invite_by_id(integer()) :: {:ok, Invite.t()} | :error
  def fetch_usable_invite_by_id(id) when is_integer(id) do
    one_usable_invite(from(i in Invite, where: i.id == ^id))
  end

  @doc "Revokes an invite that has not been spent."
  @spec delete_invite(integer()) :: :ok | {:error, :not_found}
  def delete_invite(id) do
    case Repo.get(Invite, id) do
      nil ->
        {:error, :not_found}

      invite ->
        Repo.delete!(invite)
        :ok
    end
  end

  defp one_usable_invite(query) do
    query = from(i in query, where: is_nil(i.consumed_at) and i.expires_at > ^now())

    case Repo.one(query) do
      nil -> :error
      invite -> {:ok, invite}
    end
  end

  # Spending is a guarded update rather than a read and a write, so the row
  # itself decides which of two concurrent registrations gets it.
  defp spend_invite(_repo, nil, _user), do: {:ok, nil}

  defp spend_invite(repo, %Invite{} = invite, user) do
    query =
      from(i in Invite,
        where: i.id == ^invite.id and is_nil(i.consumed_at) and i.expires_at > ^now()
      )

    case repo.update_all(query, set: [consumed_at: now(), consumed_by_user_id: user.id]) do
      {1, _} -> {:ok, invite.id}
      {0, _} -> {:error, :invite_spent}
    end
  end

  ## Passkeys

  @doc "A user's passkeys, newest first."
  @spec list_credentials(User.t()) :: [Credential.t()]
  def list_credentials(user) do
    Repo.all(from(c in Credential, where: c.user_id == ^user.id, order_by: [desc: c.id]))
  end

  @doc "The `{credential id, COSE key}` pairs `wax_` needs to verify an assertion."
  @spec credential_keys(User.t()) :: [{binary(), map()}]
  def credential_keys(user) do
    user
    |> list_credentials()
    |> Enum.map(&{&1.credential_id, Credential.decode_key(&1.public_key)})
  end

  @doc "Registers another passkey for an existing user."
  @spec add_credential(User.t(), map()) :: {:ok, Credential.t()} | {:error, Ecto.Changeset.t()}
  def add_credential(user, attrs) do
    %Credential{}
    |> Credential.changeset(Map.put(attrs, :user_id, user.id))
    |> Repo.insert()
  end

  @doc """
  Records a successful assertion, refusing a counter that failed to advance.

  An authenticator that reports a count no higher than the one it last
  reported is the signal that the credential has been cloned. Authenticators
  that do not count at all report zero forever, which is allowed.
  """
  @spec record_authentication(User.t(), binary(), non_neg_integer()) ::
          {:ok, Credential.t()} | {:error, :unknown_credential | :counter_did_not_advance}
  def record_authentication(user, credential_id, sign_count) do
    case Repo.get_by(Credential, user_id: user.id, credential_id: credential_id) do
      nil ->
        {:error, :unknown_credential}

      credential ->
        cond do
          sign_count == 0 and credential.sign_count == 0 ->
            {:ok, touch_credential(credential, sign_count)}

          sign_count > credential.sign_count ->
            {:ok, touch_credential(credential, sign_count)}

          true ->
            {:error, :counter_did_not_advance}
        end
    end
  end

  defp touch_credential(credential, sign_count) do
    credential
    |> Ecto.Changeset.change(sign_count: sign_count, last_used_at: now())
    |> Repo.update!()
  end

  @doc """
  Removes a passkey, refusing to remove the last one.

  A user with no passkeys cannot sign in, and recovery is an operator action.
  """
  @spec delete_credential(User.t(), integer()) :: :ok | {:error, :not_found | :last_credential}
  def delete_credential(user, id) do
    case Repo.get_by(Credential, id: id, user_id: user.id) do
      nil ->
        {:error, :not_found}

      credential ->
        if Repo.aggregate(from(c in Credential, where: c.user_id == ^user.id), :count) <= 1 do
          {:error, :last_credential}
        else
          Repo.delete!(credential)
          :ok
        end
    end
  end

  ## SSH keys

  @doc """
  Registers a public key for a user.

  A fingerprint already on file is refused whoever pastes it, so one key never
  names two people and a push can always be attributed.
  """
  @spec add_ssh_key(User.t(), String.t(), String.t() | nil) ::
          {:ok, SshKey.t()}
          | {:error, :unreadable | :unsupported_algorithm | :weak_key | :already_registered}
  def add_ssh_key(user, text, label \\ nil) do
    with {:ok, attrs} <- SshKey.parse(text, label) do
      %SshKey{}
      |> SshKey.changeset(Map.put(attrs, :user_id, user.id))
      |> Repo.insert()
      |> case do
        {:ok, key} -> {:ok, key}
        {:error, _changeset} -> {:error, :already_registered}
      end
    end
  end

  @doc "A user's keys, newest first."
  @spec list_ssh_keys(User.t()) :: [SshKey.t()]
  def list_ssh_keys(user) do
    Repo.all(from(k in SshKey, where: k.user_id == ^user.id, order_by: [desc: k.id]))
  end

  @doc """
  The user behind a key `ssh` offered, by fingerprint.

  This is the whole of SSH authentication: one indexed read, the same shape as
  verifying an API token.
  """
  @spec fetch_user_by_ssh_fingerprint(binary()) :: {:ok, User.t()} | :error
  def fetch_user_by_ssh_fingerprint(fingerprint) when is_binary(fingerprint) do
    query =
      from(k in SshKey,
        join: u in assoc(k, :user),
        where: k.fingerprint == ^fingerprint,
        select: {k, u}
      )

    case Repo.one(query) do
      nil -> :error
      {key, user} -> {:ok, touch(SshKey, key, user)}
    end
  end

  @doc "Revokes a key. Connections already authenticated run to completion."
  @spec delete_ssh_key(User.t(), integer()) :: :ok | {:error, :not_found}
  def delete_ssh_key(user, id) do
    case Repo.get_by(SshKey, id: id, user_id: user.id) do
      nil ->
        {:error, :not_found}

      key ->
        Repo.delete!(key)
        :ok
    end
  end

  ## Browser sessions

  @doc "Mints a session and returns the raw token for the cookie."
  @spec create_session(User.t()) :: binary()
  def create_session(user) do
    token = :crypto.strong_rand_bytes(@token_bytes)

    Repo.insert!(%Session{
      user_id: user.id,
      token_hash: hash(token),
      last_used_at: now()
    })

    token
  end

  @doc "The user behind a session cookie, if the session is live."
  @spec fetch_user_by_session_token(binary()) :: {:ok, User.t()} | :error
  def fetch_user_by_session_token(token) when is_binary(token) do
    cutoff = DateTime.add(now(), -@session_validity_days * 24 * 3600, :second)

    query =
      from(s in Session,
        join: u in assoc(s, :user),
        where: s.token_hash == ^hash(token) and s.last_used_at > ^cutoff,
        select: {s, u}
      )

    case Repo.one(query) do
      nil -> :error
      {session, user} -> {:ok, touch(Session, session, user)}
    end
  end

  @doc "Ends one session."
  @spec delete_session(binary()) :: :ok
  def delete_session(token) when is_binary(token) do
    Repo.delete_all(from(s in Session, where: s.token_hash == ^hash(token)))
    :ok
  end

  ## API tokens

  @doc """
  Mints an API token and returns it in the clear, the only time it is readable.

  The `pinha_` prefix exists so that a leaked token is recognizable to secret
  scanners.
  """
  @spec create_api_token(User.t(), String.t(), DateTime.t() | nil) ::
          {:ok, String.t(), ApiToken.t()} | {:error, Ecto.Changeset.t()}
  def create_api_token(user, label, expires_at \\ nil) do
    secret =
      @token_prefix <> Base.url_encode64(:crypto.strong_rand_bytes(@token_bytes), padding: false)

    attrs = %{
      token_hash: hash(secret),
      label: label,
      expires_at: expires_at,
      user_id: user.id
    }

    case %ApiToken{} |> ApiToken.changeset(attrs) |> Repo.insert() do
      {:ok, token} -> {:ok, secret, token}
      {:error, changeset} -> {:error, changeset}
    end
  end

  @doc "A user's tokens, newest first."
  @spec list_api_tokens(User.t()) :: [ApiToken.t()]
  def list_api_tokens(user) do
    Repo.all(from(t in ApiToken, where: t.user_id == ^user.id, order_by: [desc: t.id]))
  end

  @doc """
  The user behind an API token, given the email git sent as the username.

  The email must match the token's owner, so a token stolen from one account
  cannot be used to act as another.
  """
  @spec fetch_user_by_api_token(String.t(), String.t()) :: {:ok, User.t()} | :error
  def fetch_user_by_api_token(email, secret) when is_binary(email) and is_binary(secret) do
    query =
      from(t in ApiToken,
        join: u in assoc(t, :user),
        where: t.token_hash == ^hash(secret),
        where: u.email == ^String.downcase(String.trim(email)),
        where: is_nil(t.expires_at) or t.expires_at > ^now(),
        select: {t, u}
      )

    case Repo.one(query) do
      nil -> :error
      {token, user} -> {:ok, touch(ApiToken, token, user)}
    end
  end

  @doc "Revokes a token."
  @spec delete_api_token(User.t(), integer()) :: :ok | {:error, :not_found}
  def delete_api_token(user, id) do
    case Repo.get_by(ApiToken, id: id, user_id: user.id) do
      nil ->
        {:error, :not_found}

      token ->
        Repo.delete!(token)
        :ok
    end
  end

  ## Shared

  defp touch(schema, record, user) do
    stale? =
      is_nil(record.last_used_at) or
        DateTime.diff(now(), record.last_used_at, :second) > @touch_after_seconds

    if stale? do
      Repo.update_all(from(r in schema, where: r.id == ^record.id), set: [last_used_at: now()])
    end

    user
  end

  defp hash(value), do: :crypto.hash(:sha256, value)

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
