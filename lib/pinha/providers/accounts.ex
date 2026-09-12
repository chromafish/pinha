defmodule Pinha.Providers.Accounts do
  @moduledoc """
  Links between Pinha users and their accounts on providers.

  Linking records an identity a user access token belonged to; unlinking
  deletes it. Either way, a link that goes away is announced to subscribers
  as an `account_unlinked` event, in the same transaction, so features that
  acted for it notice.
  """

  @behaviour Pinha.Providers.EventSubscriber

  import Ecto.Query

  alias Pinha.Accounts.User
  alias Pinha.Providers
  alias Pinha.Providers.Account
  alias Pinha.Repo

  @doc "The user's account on `provider`, or nil."
  @spec get(User.t() | integer() | nil, String.t()) :: Account.t() | nil
  def get(nil, _provider), do: nil
  def get(%User{id: id}, provider), do: get(id, provider)

  def get(user_id, provider) when is_integer(user_id) do
    Repo.one(from(a in Account, where: a.user_id == ^user_id and a.provider == ^provider))
  end

  @doc "Every account the user linked, keyed by provider name."
  @spec for_user(User.t()) :: %{String.t() => Account.t()}
  def for_user(%User{id: id}) do
    from(a in Account, where: a.user_id == ^id)
    |> Repo.all()
    |> Map.new(&{&1.provider, &1})
  end

  @doc """
  Links `identity` on `provider` to `user`.

  The same identity again refreshes its login. A different identity replaces
  the user's link, which counts as unlinking the old one. An identity already
  linked to another user is refused.
  """
  @spec link(User.t(), String.t(), %{external_id: String.t(), login: String.t()}) ::
          {:ok, Account.t()} | {:error, :taken | Ecto.Changeset.t()}
  def link(%User{} = user, provider, %{external_id: external_id, login: login}) do
    Repo.transaction(fn ->
      taken =
        Repo.one(
          from(a in Account,
            where:
              a.provider == ^provider and a.external_id == ^external_id and
                a.user_id != ^user.id,
            lock: "FOR UPDATE"
          )
        )

      current = get(user, provider)

      cond do
        taken ->
          Repo.rollback(:taken)

        current && current.external_id == external_id ->
          current |> Account.changeset(%{login: login}) |> update_or_rollback()

        true ->
          if current, do: delete_and_announce(current)

          %Account{}
          |> Account.changeset(%{
            user_id: user.id,
            provider: provider,
            external_id: external_id,
            login: login
          })
          |> Repo.insert()
          |> case do
            {:ok, account} ->
              account

            {:error, %Ecto.Changeset{errors: errors} = changeset} ->
              rollback_insert(errors, changeset)
          end
      end
    end)
  end

  @doc "Removes the user's link to `provider`, if any."
  @spec unlink(User.t(), String.t()) :: {:ok, Account.t()} | {:error, :not_linked}
  def unlink(%User{} = user, provider) do
    Repo.transaction(fn ->
      case get(user, provider) do
        nil -> Repo.rollback(:not_linked)
        account -> delete_and_announce(account)
      end
    end)
  end

  @doc """
  Removes the link for an identity the provider says withdrew its
  authorization.
  """
  @spec unlink_identity(String.t(), String.t()) :: :ok
  def unlink_identity(provider, external_id) do
    Repo.transaction(fn ->
      from(a in Account, where: a.provider == ^provider and a.external_id == ^external_id)
      |> Repo.all()
      |> Enum.each(&delete_and_announce/1)
    end)

    :ok
  end

  @doc "Unlinks an identity whose authorization the provider reports revoked."
  @impl Pinha.Providers.EventSubscriber
  def handle_event(provider, %{"type" => "authorization_revoked", "external_id" => external_id}) do
    unlink_identity(provider, to_string(external_id))
  end

  def handle_event(_provider, _event), do: :ok

  defp delete_and_announce(account) do
    Repo.delete!(account)

    Providers.dispatch(account.provider, %{
      "type" => "account_unlinked",
      "account_id" => account.id,
      "user_id" => account.user_id
    })

    account
  end

  defp update_or_rollback(changeset) do
    case Repo.update(changeset) do
      {:ok, account} -> account
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  # Two users linking one identity at once: the loser hits the unique index.
  defp rollback_insert(errors, changeset) do
    if Keyword.has_key?(errors, :provider),
      do: Repo.rollback(:taken),
      else: Repo.rollback(changeset)
  end
end
