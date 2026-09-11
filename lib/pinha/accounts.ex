defmodule Pinha.Accounts do
  @moduledoc """
  Users, their passkeys, browser sessions, and the tokens git sends.

  Every secret this module hands out is returned once, in the clear, and kept
  only as a SHA-256: a session token, an API token. Lookups hash the presented
  value and read an index, so verifying a token on each git request is one
  indexed read rather than a key derivation.
  """

  import Ecto.Query

  alias Ecto.Multi
  alias Pinha.Accounts.ApiToken
  alias Pinha.Accounts.Credential
  alias Pinha.Accounts.Session
  alias Pinha.Accounts.User
  alias Pinha.Repo

  @session_validity_days 60
  @token_bytes 32
  @token_prefix "pinha_"
  # Reading a token is a read. Recording that it was used is a write, so it
  # happens at most once an hour per row rather than once per request.
  @touch_after_seconds 3600

  ## Users

  @doc "How many users exist."
  @spec count_users() :: non_neg_integer()
  def count_users, do: Repo.aggregate(User, :count)

  @doc """
  Whether sign-up is currently accepted.

  The first person to reach a fresh server claims it; after that the operator
  decides with `PINHA_SIGNUP_OPEN`.
  """
  @spec signup_open?() :: boolean()
  def signup_open?, do: count_users() == 0 or Pinha.Config.signup_open?()

  @doc "Fetches a user by the WebAuthn handle an authenticator returned."
  @spec fetch_user_by_handle(binary()) :: {:ok, User.t()} | :error
  def fetch_user_by_handle(handle) when is_binary(handle) do
    case Repo.get_by(User, handle: handle) do
      nil -> :error
      user -> {:ok, user}
    end
  end

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
  lands without the other.
  """
  @spec register_user(map(), map()) ::
          {:ok, %{user: User.t(), credential: Credential.t()}}
          | {:error, atom(), Ecto.Changeset.t()}
  def register_user(user_attrs, credential_attrs) do
    Multi.new()
    |> Multi.insert(:user, User.changeset(%User{}, user_attrs))
    |> Multi.insert(:credential, fn %{user: user} ->
      Credential.changeset(%Credential{}, Map.put(credential_attrs, :user_id, user.id))
    end)
    |> Repo.transaction()
    |> case do
      {:ok, result} -> {:ok, result}
      {:error, step, changeset, _changes} -> {:error, step, changeset}
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
