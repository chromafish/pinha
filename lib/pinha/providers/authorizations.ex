defmodule Pinha.Providers.Authorizations do
  @moduledoc """
  One round trip through a provider's consent screen.

  `start/5` stores the SHA-256 of a random `state`, bound to the user who
  started it and to the handler module that receives the result, and returns
  the provider URL to send the browser to. `finish/3` is the callback: it
  spends the pending row in one statement, so a state is used once, and
  refuses one that is unknown, expired, or started by someone other than the
  signed-in user, so an attacker cannot finish their own authorization in a
  victim's browser.

  The code exchange, the handler, and revoking the token afterwards all run
  in one process hidden from runtime introspection; the request process
  waiting on it never holds the token.
  """

  import Ecto.Query

  alias Pinha.Accounts.User
  alias Pinha.Providers
  alias Pinha.Providers.Authorization
  alias Pinha.Providers.AuthorizationHandler
  alias Pinha.Providers.Error
  alias Pinha.Providers.Secret
  alias Pinha.Repo

  require Logger

  @ttl_seconds 600
  @state_bytes 32

  # Only what a provider sends back that is not a credential reaches the
  # handler.
  @callback_keys ["installation_id", "setup_action"]

  @doc """
  Starts an authorization for `user`, handled by `handler` with `params`.

  `params` must be JSON-encodable and hold no secrets; a `"return_to"` path
  says where a declined authorization sends the user back to. `url_opts` go
  to the provider's `authorization_url/2`.
  """
  @spec start(User.t(), module(), module(), map(), keyword()) ::
          {:ok, String.t()} | {:error, Ecto.Changeset.t()}
  def start(%User{} = user, provider, handler, params \\ %{}, url_opts \\ []) do
    state = @state_bytes |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

    expires_at =
      DateTime.utc_now() |> DateTime.add(@ttl_seconds, :second) |> DateTime.truncate(:second)

    %Authorization{
      state_hash: hash(state),
      user_id: user.id,
      provider: provider.name(),
      handler: inspect(handler),
      params: params,
      expires_at: expires_at
    }
    |> Repo.insert()
    |> case do
      {:ok, _authorization} -> {:ok, provider.authorization_url(state, url_opts)}
      {:error, changeset} -> {:error, changeset}
    end
  end

  @doc """
  Finishes the authorization the provider redirected back with.

  Returns the handler's result, `{:declined, return_to}` when the user
  declined, or `{:refused, reason}` when the callback does not match a
  pending authorization of this user.
  """
  @spec finish(module(), User.t(), map()) ::
          {:ok, AuthorizationHandler.result()}
          | {:error, AuthorizationHandler.result()}
          | {:declined, String.t()}
          | {:refused, :unknown | :expired | :invalid_handler}
  def finish(provider, %User{} = user, callback_params) do
    with {:ok, authorization} <- spend(provider, user, callback_params["state"]),
         {:ok, handler} <- handler(authorization.handler) do
      return_to = authorization.params["return_to"] || "/"

      case callback_params do
        %{"error" => _} ->
          {:declined, return_to}

        %{"code" => code} when is_binary(code) and code != "" ->
          context = %{
            user: user,
            provider: provider,
            params: authorization.params,
            callback: Map.take(callback_params, @callback_keys)
          }

          Providers.sensitive(fn -> run(handler, provider, code, context, return_to) end)
          |> normalize(return_to)

        _ ->
          # No code and no error: the provider sent the user back without
          # finishing, which is what an installation request looks like.
          run_without_code(
            handler,
            context_without_token(provider, user, authorization, callback_params)
          )
      end
    end
  end

  @doc "Deletes authorizations that expired before now."
  @spec prune_expired() :: non_neg_integer()
  def prune_expired do
    now = DateTime.utc_now()
    {count, _} = Repo.delete_all(from(a in Authorization, where: a.expires_at < ^now))
    count
  end

  # Deleted in the same statement that finds it, and only for the user it
  # belongs to: a state is spent once, and another user's callback leaves the
  # owner's authorization untouched.
  defp spend(_provider, _user, state) when not is_binary(state) or state == "",
    do: {:refused, :unknown}

  defp spend(provider, user, state) do
    query =
      from(a in Authorization,
        where:
          a.state_hash == ^hash(state) and a.user_id == ^user.id and
            a.provider == ^provider.name(),
        select: a
      )

    case Repo.delete_all(query) do
      {1, [authorization]} ->
        if DateTime.compare(authorization.expires_at, DateTime.utc_now()) == :gt do
          {:ok, authorization}
        else
          {:refused, :expired}
        end

      {0, _} ->
        {:refused, :unknown}
    end
  end

  defp handler(name) do
    module = String.to_existing_atom("Elixir." <> name)

    if Code.ensure_loaded?(module) and function_exported?(module, :handle_authorization, 1) and
         AuthorizationHandler in behaviours(module) do
      {:ok, module}
    else
      {:refused, :invalid_handler}
    end
  rescue
    ArgumentError -> {:refused, :invalid_handler}
  end

  defp behaviours(module) do
    module.module_info(:attributes) |> Keyword.get_values(:behaviour) |> List.flatten()
  end

  # Runs inside the sensitive process. The token is revoked whatever the
  # handler did, and a failure to revoke is logged without the token.
  defp run(handler, provider, code, context, return_to) do
    case provider.exchange_code(code) do
      {:ok, %Secret{} = token} ->
        try do
          handler.handle_authorization(Map.put(context, :token, token))
        after
          revoke(provider, token)
        end

      {:error, %Error{message: message}} ->
        {:error,
         %{to: return_to, message: "#{provider.label()} refused the authorization: #{message}"}}
    end
  end

  defp run_without_code(handler, context) do
    if function_exported?(handler, :handle_incomplete, 1) do
      handler.handle_incomplete(context)
    else
      {:error,
       %{to: context.params["return_to"] || "/", message: "The authorization did not complete."}}
    end
  end

  defp context_without_token(provider, user, authorization, callback_params) do
    %{
      user: user,
      provider: provider,
      params: authorization.params,
      callback: Map.take(callback_params, @callback_keys)
    }
  end

  defp revoke(provider, token) do
    case provider.revoke_token(token) do
      :ok ->
        :ok

      {:error, %Error{message: message}} ->
        Logger.warning("revoking a #{provider.name()} user token failed: #{message}")
    end
  end

  defp normalize({:ok, %{to: _, message: _}} = result, _return_to), do: result
  defp normalize({:error, %{to: _, message: _}} = result, _return_to), do: result

  defp normalize({:error, %Error{message: message}}, return_to),
    do: {:error, %{to: return_to, message: message}}

  defp normalize(_other, return_to),
    do: {:error, %{to: return_to, message: "The authorization could not be completed."}}

  defp hash(state), do: :crypto.hash(:sha256, state)
end
