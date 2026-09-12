defmodule Pinha.Providers.Provider do
  @moduledoc """
  What a forge implements to be a provider.

  A provider names itself, says whether the operator configured it, lists the
  capabilities it implements, runs the consent round trip, and turns its
  webhook deliveries into provider events. Every function that talks to the
  provider returns `Pinha.Providers.Error` on failure and takes or returns
  credentials only as `Pinha.Providers.Secret`.
  """

  alias Pinha.Providers.Error
  alias Pinha.Providers.Secret

  @typedoc "An identity on the provider."
  @type identity :: %{external_id: String.t(), login: String.t()}

  @doc "The name stored in `provider` columns, such as `\"github\"`."
  @callback name() :: String.t()

  @doc "The name shown to people, such as `\"GitHub\"`."
  @callback label() :: String.t()

  @doc "Whether the operator supplied everything the provider needs."
  @callback configured?() :: boolean()

  @doc "Capability behaviour to the module implementing it."
  @callback capabilities() :: %{module() => module()}

  @doc """
  Where to send the browser for one authorization carrying `state`.

  `install: true` sends it through installing the provider's app first.
  """
  @callback authorization_url(state :: String.t(), opts :: keyword()) :: String.t()

  @doc "Exchanges the callback's code for a user access token."
  @callback exchange_code(code :: String.t()) :: {:ok, Secret.t()} | {:error, Error.t()}

  @doc "Who a user access token belongs to."
  @callback identity(Secret.t()) :: {:ok, identity()} | {:error, Error.t()}

  @doc "Revokes a user access token."
  @callback revoke_token(Secret.t()) :: :ok | {:error, Error.t()}

  @doc """
  Checks a webhook delivery against the webhook secret and returns its ID.

  `headers` are lowercase names with their values.
  """
  @callback verify_delivery(headers :: %{String.t() => String.t()}, body :: binary()) ::
              {:ok, String.t()} | {:error, :invalid_signature | :malformed}

  @doc """
  Provider events carried by one verified delivery.

  Events are plain maps with string keys and a `"type"`, so they can be job
  arguments.
  """
  @callback events(headers :: %{String.t() => String.t()}, payload :: map()) :: [map()]
end
