defmodule Pinha.Providers.AuthorizationHandler do
  @moduledoc """
  What a feature implements to receive the result of an authorization it
  started.

  The handler runs in a process hidden from runtime introspection, holds the
  user access token only for the length of the call, and the token is revoked
  when it returns. The result says where to send the browser and what to tell
  the user, and may name an audit event for the callback request to record.
  """

  alias Pinha.Accounts.User
  alias Pinha.Providers.Secret

  @type context :: %{
          user: User.t(),
          provider: module(),
          token: Secret.t(),
          params: map(),
          callback: %{String.t() => String.t()}
        }

  @type result :: %{
          required(:to) => String.t(),
          required(:message) => String.t(),
          optional(:audit) => {String.t(), map()}
        }

  @doc """
  Does the feature's work with the user access token.

  `params` are those the feature stored when it started the authorization;
  `callback` holds the provider's non-secret callback parameters, such as an
  installation ID.
  """
  @callback handle_authorization(context()) :: {:ok, result()} | {:error, result()}

  @doc """
  Handles a callback that came back with neither a code nor an error, such
  as an installation an organization owner still has to approve. There is no
  token in the context.
  """
  @callback handle_incomplete(map()) :: {:ok, result()} | {:error, result()}

  @optional_callbacks handle_incomplete: 1
end
