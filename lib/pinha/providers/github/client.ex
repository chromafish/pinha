defmodule Pinha.Providers.GitHub.Client do
  @moduledoc """
  GitHub's REST API, called with `Req`.

  Requests authenticate as the app with a JWT signed by its private key, as
  an installation with an installation token, as a user with a user access
  token, or as the OAuth client with its ID and secret. Every credential is a
  `Pinha.Providers.Secret` until the moment it becomes a header.

  Each request is one span carrying the method, the path, and the status,
  never headers, query strings, or bodies. A failure is a
  `Pinha.Providers.Error` holding the status and GitHub's message; callers
  that know what a status means for them classify it further.
  """

  alias Pinha.Providers.Error
  alias Pinha.Providers.GitHub.Config
  alias Pinha.Providers.Secret

  require OpenTelemetry.Tracer, as: Tracer

  @api_version "2022-11-28"

  @type auth :: {:bearer, Secret.t()} | :app | :client | :none
  @type response :: %{status: pos_integer(), body: term(), headers: map()}

  @doc """
  Calls the API and returns a 2xx response, or the failure.

  Options: `:auth`, `:json` for a request body, and `:base` of `:api`
  (default) or `:web` for the endpoints on github.com itself.
  """
  @spec request(atom(), String.t(), keyword()) :: {:ok, response()} | {:error, Error.t()}
  def request(method, path, opts \\ []) do
    base = Keyword.get(opts, :base, :api)

    Tracer.with_span "github #{method |> Atom.to_string() |> String.upcase()}",
                     %{
                       kind: :client,
                       attributes: [
                         {"http.request.method", method |> Atom.to_string() |> String.upcase()},
                         {"url.path", path},
                         {"provider", "github"}
                       ]
                     } do
      result =
        with {:ok, headers} <- auth_headers(Keyword.get(opts, :auth, :none)) do
          send_request(method, path, base, headers, opts)
        end

      case result do
        {:ok, response} ->
          Tracer.set_attribute("http.response.status_code", response.status)
          {:ok, response}

        {:error, %Error{} = error} ->
          if error.status, do: Tracer.set_attribute("http.response.status_code", error.status)
          Tracer.set_attributes([{"error", true}, {"error.message", error.message}])
          Tracer.set_status(OpenTelemetry.status(:error, error.message))
          {:error, error}
      end
    end
  end

  defp send_request(method, path, base, headers, opts) do
    req =
      Req.new(
        method: method,
        base_url: if(base == :web, do: Config.web_url(), else: Config.api_url()),
        url: path,
        headers:
          [
            {"accept",
             if(base == :web, do: "application/json", else: "application/vnd.github+json")},
            {"x-github-api-version", @api_version},
            {"user-agent", "pinha"}
          ] ++ headers,
        retry: false,
        receive_timeout: 30_000
      )
      |> Req.merge(Config.req_options())

    req = if json = Keyword.get(opts, :json), do: Req.merge(req, json: json), else: req

    case Req.request(req) do
      {:ok, %Req.Response{status: status} = response} when status in 200..299 ->
        {:ok, %{status: status, body: response.body, headers: response.headers}}

      {:ok, %Req.Response{} = response} ->
        {:error, error_for(response)}

      {:error, exception} ->
        {:error, Error.transient("could not reach GitHub: #{transport_reason(exception)}")}
    end
  end

  # A rate limit is a 403 or 429 that says so; everything else keeps its
  # status for the caller to classify.
  defp error_for(%Req.Response{status: status, body: body, headers: headers}) do
    message = message(body) || "GitHub answered #{status}"

    if status == 429 or (status == 403 and rate_limited?(headers, message)) do
      Error.transient("rate limited by GitHub: #{message}", status)
    else
      Error.transient(message, status)
    end
  end

  defp rate_limited?(headers, message) do
    Map.get(headers, "x-ratelimit-remaining") == ["0"] or message =~ ~r/rate limit/i
  end

  @doc "GitHub's message from an error body, if it has one."
  @spec message(term()) :: String.t() | nil
  def message(%{"message" => message} = body) when is_binary(message) do
    case body do
      %{"errors" => [%{"message" => detail} | _]} when is_binary(detail) ->
        message <> ": " <> detail

      _ ->
        message
    end
  end

  def message(%{"error_description" => message}) when is_binary(message), do: message
  def message(_body), do: nil

  defp transport_reason(%{reason: reason}) when is_atom(reason), do: Atom.to_string(reason)
  defp transport_reason(exception) when is_exception(exception), do: inspect(exception.__struct__)
  defp transport_reason(_other), do: "unknown error"

  defp auth_headers(:none), do: {:ok, []}

  defp auth_headers({:bearer, %Secret{} = secret}),
    do: {:ok, [{"authorization", "Bearer " <> Secret.reveal(secret)}]}

  defp auth_headers(:app) do
    with {:ok, jwt} <- app_jwt() do
      {:ok, [{"authorization", "Bearer " <> Secret.reveal(jwt)}]}
    end
  end

  defp auth_headers(:client) do
    credentials = Base.encode64(Config.client_id() <> ":" <> Config.client_secret())
    {:ok, [{"authorization", "Basic " <> credentials}]}
  end

  @doc """
  A JWT that authenticates as the app for ten minutes, signed RS256 with the
  app's private key.

  `iat` is backdated a minute for clock drift, as GitHub recommends.
  """
  @spec app_jwt(integer()) :: {:ok, Secret.t()} | {:error, Error.t()}
  def app_jwt(now \\ System.system_time(:second)) do
    with {:ok, key} <- private_key() do
      header = encode_segment(%{"alg" => "RS256", "typ" => "JWT"})

      claims =
        encode_segment(%{"iat" => now - 60, "exp" => now + 540, "iss" => Config.app_id()})

      input = header <> "." <> claims
      signature = :public_key.sign(input, :sha256, key)
      {:ok, Secret.new(input <> "." <> Base.url_encode64(signature, padding: false))}
    end
  end

  defp private_key do
    with [entry | _] <- :public_key.pem_decode(Config.private_key()),
         key when elem(key, 0) == :RSAPrivateKey <- :public_key.pem_entry_decode(entry) do
      {:ok, key}
    else
      _ -> {:error, Error.transient("the GitHub App private key is not a readable RSA key")}
    end
  rescue
    _ -> {:error, Error.transient("the GitHub App private key is not a readable RSA key")}
  end

  defp encode_segment(map), do: map |> Jason.encode!() |> Base.url_encode64(padding: false)

  @doc """
  An installation token for `installation_id`, limited to `repository_ids`
  and `permissions`.

  A missing installation, a suspended one, and repositories outside it are
  terminal, with the reason each means.
  """
  @spec installation_token(String.t(), [String.t()], map()) ::
          {:ok, Secret.t()} | {:error, Error.t()}
  def installation_token(installation_id, repository_ids, permissions) do
    body = %{
      "repository_ids" => Enum.map(repository_ids, &to_integer/1),
      "permissions" => permissions
    }

    case request(:post, "/app/installations/#{installation_id}/access_tokens",
           auth: :app,
           json: body
         ) do
      {:ok, %{body: %{"token" => token}}} ->
        {:ok, Secret.new(token)}

      {:ok, _response} ->
        {:error, Error.transient("GitHub returned no installation token")}

      {:error, %Error{status: 404} = error} ->
        {:error, Error.terminal(:installation_removed, error.message, 404)}

      {:error, %Error{status: 403, message: message} = error} ->
        if message =~ ~r/suspend/i do
          {:error, Error.terminal(:installation_suspended, message, 403)}
        else
          {:error, error}
        end

      {:error, %Error{status: 422} = error} ->
        {:error, Error.terminal(:target_unreachable, error.message, 422)}

      {:error, error} ->
        {:error, error}
    end
  end

  @doc "The installation on the account named `login`, looked up as the app."
  @spec account_installation(String.t()) ::
          {:ok, map()} | {:error, :not_installed | Error.t()}
  def account_installation(login) do
    case request(:get, "/users/#{URI.encode(login)}/installation", auth: :app) do
      {:ok, %{body: body}} -> {:ok, installation(body)}
      {:error, %Error{status: 404}} -> {:error, :not_installed}
      {:error, error} -> {:error, error}
    end
  end

  @doc "One installation by ID, looked up as the app."
  @spec get_installation(String.t()) :: {:ok, map()} | {:error, Error.t()}
  def get_installation(installation_id) do
    case request(:get, "/app/installations/#{installation_id}", auth: :app) do
      {:ok, %{body: body}} ->
        {:ok, installation(body)}

      {:error, %Error{status: 404} = error} ->
        {:error, Error.terminal(:installation_removed, error.message, 404)}

      {:error, error} ->
        {:error, error}
    end
  end

  defp installation(body) do
    account = body["account"] || %{}

    %{
      id: to_string(body["id"]),
      account_login: account["login"],
      account_id: to_string(account["id"]),
      account_type: if(account["type"] == "Organization", do: "organization", else: "user"),
      suspended?: not is_nil(body["suspended_at"])
    }
  end

  @doc "Exchanges an authorization callback's code for a user access token."
  @spec exchange_code(String.t()) :: {:ok, Secret.t()} | {:error, Error.t()}
  def exchange_code(code) do
    case request(:post, "/login/oauth/access_token",
           base: :web,
           json: %{
             "client_id" => Config.client_id(),
             "client_secret" => Config.client_secret(),
             "code" => code
           }
         ) do
      {:ok, %{body: %{"access_token" => token}}} when is_binary(token) ->
        {:ok, Secret.new(token)}

      {:ok, %{body: body}} ->
        {:error, Error.transient(message(body) || "GitHub did not return a token")}

      {:error, error} ->
        {:error, error}
    end
  end

  @doc "Revokes a user access token, authenticating as the OAuth client."
  @spec revoke(Secret.t()) :: :ok | {:error, Error.t()}
  def revoke(%Secret{} = token) do
    case request(:delete, "/applications/#{Config.client_id()}/token",
           auth: :client,
           json: %{"access_token" => Secret.reveal(token)}
         ) do
      {:ok, _response} -> :ok
      {:error, %Error{status: 404}} -> :ok
      {:error, error} -> {:error, error}
    end
  end

  defp to_integer(value) when is_integer(value), do: value
  defp to_integer(value) when is_binary(value), do: String.to_integer(value)
end
