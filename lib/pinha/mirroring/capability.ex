defmodule Pinha.Mirroring.Capability do
  @moduledoc """
  What a provider implements to support repository mirroring.

  Connecting a target runs with the connecting user's access token, inside an
  authorization. Everything after that runs with short-lived credentials the
  provider mints from its own, scoped to the one target. Failures are
  `Pinha.Providers.Error`s; a terminal one names the mirror's disabled
  reason.
  """

  alias Pinha.Mirroring.Mirror
  alias Pinha.Providers.Account
  alias Pinha.Providers.Error
  alias Pinha.Providers.Secret

  @typedoc """
  What a connect form chose: `"account"` (a login), `"mode"` (`"new"` or
  `"existing"`), `"name"`, and for a new repository `"private"`,
  `"has_issues"`, `"has_projects"`, and `"has_wiki"`.
  """
  @type connect_params :: %{String.t() => term()}

  @typedoc "The target a connect produced, as mirror attributes."
  @type target :: %{
          installation_id: String.t(),
          target_id: String.t(),
          target_name: String.t(),
          target_url: String.t(),
          target_account_type: String.t(),
          state: String.t()
        }

  @typedoc """
  A push prepared for one sync: the URL git pushes to, the one git config
  value that authenticates it, every secret to scrub from git's output, and
  the target's current name and URL.
  """
  @type push :: %{
          url: String.t(),
          auth_header: Secret.t(),
          secrets: [Secret.t()],
          target_name: String.t(),
          target_url: String.t()
        }

  @doc """
  Options for starting the connect authorization, such as whether the app
  must be installed on the chosen account first.
  """
  @callback authorization_options(Account.t(), connect_params()) ::
              {:ok, keyword()} | {:error, Error.t()}

  @doc """
  Verifies and creates or looks up the target with the user's token.

  The context carries `:token`, the user's `:account`, the stored `:params`,
  and the provider's `:callback` parameters.
  """
  @callback connect(map()) :: {:ok, target()} | {:error, Error.t()}

  @doc """
  Checks the connecting account may still write the target and prepares a
  push with a credential scoped to it.
  """
  @callback prepare_sync(Mirror.t(), Account.t()) :: {:ok, push()} | {:error, Error.t()}

  @doc "What a failed push's output means: a terminal reason, or transient."
  @callback push_failure(output :: String.t()) :: {:terminal, atom()} | :transient

  @doc "Where the owner grants the provider access to the target."
  @callback access_settings_url(Mirror.t()) :: String.t()
end
