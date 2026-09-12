defmodule Pinha.Providers.GitHub.Mirroring do
  @moduledoc """
  Mirroring to GitHub.

  Connecting runs with the user's access token, so GitHub decides what the
  user may do: a new repository is created as them, and an existing one must
  be one they administer. Everything afterwards runs with an installation
  token minted for the one target with `contents` and `workflows` write, the
  only permissions a push needs, and acting as the app rather than as the
  user is why each sync checks the user's access to an organization target
  again.
  """

  @behaviour Pinha.Mirroring.Capability

  alias Pinha.Providers.Error
  alias Pinha.Providers.GitHub
  alias Pinha.Providers.GitHub.Client
  alias Pinha.Providers.GitHub.Config
  alias Pinha.Providers.Secret

  @push_permissions %{"contents" => "write", "workflows" => "write"}

  @write_roles ~w(admin maintain write)

  # What GitHub refuses for the content of a push rather than for a reason
  # that may pass: these disable the mirror instead of offering Retry.
  @rejected ~r/GH0\d\d|large file|secret scanning|push declined|repository rule|
              protected branch|pre-receive hook declined|refusing to delete the current branch/x

  @gone ~r/repository not found|could not read from remote repository|does not appear to be a git repository/i

  @impl true
  def authorization_options(_account, %{"account" => login}) do
    case Client.account_installation(login) do
      {:ok, %{suspended?: true}} ->
        {:error,
         Error.terminal(
           :installation_suspended,
           "the app's installation on #{login} is suspended"
         )}

      {:ok, _installation} ->
        {:ok, []}

      {:error, :not_installed} ->
        {:ok, [install: true]}

      {:error, %Error{} = error} ->
        {:error, error}
    end
  end

  @impl true
  def connect(%{token: token, account: account, params: params, callback: callback}) do
    login = params["account"]

    with {:ok, me} <- authorizing_user(token, account),
         {:ok, installation} <- installation(login, callback),
         :ok <- personal_target(installation, login, me),
         {:ok, target} <- target(token, installation, params, login) do
      {:ok, Map.put(target, :installation_id, installation.id)}
    end
  end

  # GitHub creates a personal repository under whoever authorized, so a
  # personal target is only ever the authorizing user's own account.
  defp authorizing_user(token, account) do
    case GitHub.identity(token) do
      {:ok, %{external_id: id} = me} ->
        if id == account.external_id do
          {:ok, me}
        else
          {:error,
           Error.terminal(
             :access_lost,
             "you authorized as @#{me.login}, which is not the linked account"
           )}
        end

      {:error, error} ->
        {:error, error}
    end
  end

  defp installation(login, %{"installation_id" => id}) when is_binary(id) and id != "" do
    case Client.get_installation(id) do
      {:ok, installation} -> verify_installation_account(installation, login)
      {:error, error} -> {:error, error}
    end
  end

  defp installation(login, _callback) do
    case Client.account_installation(login) do
      {:ok, installation} ->
        verify_installation_account(installation, login)

      {:error, :not_installed} ->
        {:error, Error.terminal(:target_unreachable, "the app is not installed on #{login}")}

      {:error, error} ->
        {:error, error}
    end
  end

  defp verify_installation_account(installation, login) do
    cond do
      installation.suspended? ->
        {:error,
         Error.terminal(:installation_suspended, "the installation on #{login} is suspended")}

      not same_login?(installation.account_login, login) ->
        {:error,
         Error.terminal(
           :target_unreachable,
           "the app was installed on #{installation.account_login}, not #{login}"
         )}

      true ->
        {:ok, installation}
    end
  end

  defp personal_target(%{account_type: "user"}, login, me) do
    if same_login?(login, me.login) do
      :ok
    else
      {:error,
       Error.terminal(:access_lost, "a personal mirror must be on your own account, @#{me.login}")}
    end
  end

  defp personal_target(_installation, _login, _me), do: :ok

  defp target(token, installation, %{"mode" => "new"} = params, login) do
    path =
      if installation.account_type == "organization",
        do: "/orgs/#{login}/repos",
        else: "/user/repos"

    body = %{
      "name" => params["name"],
      "private" => params["private"] != false,
      "has_issues" => params["has_issues"] == true,
      "has_projects" => params["has_projects"] == true,
      "has_wiki" => params["has_wiki"] == true,
      "auto_init" => false
    }

    case Client.request(:post, path, auth: {:bearer, token}, json: body) do
      {:ok, %{body: repository}} ->
        reachable(installation, repository)

      {:error, %Error{status: status} = error} when status in [403, 404] ->
        {:error,
         Error.terminal(
           :access_lost,
           "you may not create a repository in #{login}: #{error.message}"
         )}

      {:error, %Error{status: 422} = error} ->
        {:error, Error.terminal(:target_unreachable, error.message, 422)}

      {:error, error} ->
        {:error, error}
    end
  end

  defp target(token, installation, %{"mode" => "existing"} = params, login) do
    full_name = "#{login}/#{params["name"]}"

    case Client.request(:get, "/repos/#{full_name}", auth: {:bearer, token}) do
      {:ok, %{body: %{"permissions" => %{"admin" => true}} = repository}} ->
        reachable(installation, repository)

      {:ok, %{body: _repository}} ->
        {:error, Error.terminal(:access_lost, "you need admin access to #{full_name}")}

      {:error, %Error{status: 404}} ->
        {:error,
         Error.terminal(
           :target_unreachable,
           "GitHub shows no repository #{full_name} to the app. Add it to the app's " <>
             "installation on #{login}, then try again"
         )}

      {:error, error} ->
        {:error, error}
    end
  end

  # A repository the installation cannot reach yet is connected all the same,
  # awaiting the access its owner grants on GitHub.
  defp reachable(installation, repository) do
    target_id = to_string(repository["id"])

    state =
      case Client.installation_token(installation.id, [target_id], @push_permissions) do
        {:ok, _token} -> "active"
        {:error, %Error{reason: :target_unreachable}} -> "awaiting_access"
        {:error, error} -> {:error, error}
      end

    case state do
      {:error, error} ->
        {:error, error}

      state ->
        {:ok,
         %{
           target_id: target_id,
           target_name: repository["full_name"],
           target_url: repository["html_url"],
           target_account_type: installation.account_type,
           state: state
         }}
    end
  end

  @impl true
  def prepare_sync(mirror, account) do
    with {:ok, token} <-
           Client.installation_token(
             mirror.installation_id,
             [mirror.target_id],
             @push_permissions
           ),
         {:ok, repository} <- target_repository(token, mirror),
         :ok <- organization_access(token, mirror, account, repository) do
      header = Secret.new("Authorization: Basic " <> basic(token))

      {:ok,
       %{
         url: "#{Config.git_url()}/#{repository["full_name"]}.git",
         auth_header: header,
         secrets: [token, header],
         target_name: repository["full_name"],
         target_url: repository["html_url"]
       }}
    end
  end

  defp target_repository(token, mirror) do
    case Client.request(:get, "/repositories/#{mirror.target_id}", auth: {:bearer, token}) do
      {:ok, %{body: repository}} ->
        {:ok, repository}

      {:error, %Error{status: status} = error} when status in [403, 404] ->
        {:error, Error.terminal(:target_unreachable, error.message, status)}

      {:error, error} ->
        {:error, error}
    end
  end

  # An installation token acts as the app, so GitHub cannot tell which Pinha
  # user caused the push: the connecting user's write access to an
  # organization target is checked here, before every sync.
  defp organization_access(_token, %{target_account_type: "user"}, _account, _repository), do: :ok

  defp organization_access(token, _mirror, account, repository) do
    with {:ok, login} <- current_login(token, account) do
      path = "/repos/#{repository["full_name"]}/collaborators/#{login}/permission"

      case Client.request(:get, path, auth: {:bearer, token}) do
        {:ok, %{body: body}} ->
          if permission(body) in @write_roles do
            :ok
          else
            {:error,
             Error.terminal(
               :access_lost,
               "@#{login} no longer has write access to #{repository["full_name"]}"
             )}
          end

        {:error, %Error{status: status} = error} when status in [403, 404] ->
          {:error, Error.terminal(:access_lost, error.message, status)}

        {:error, error} ->
          {:error, error}
      end
    end
  end

  # The login recorded when the mirror was connected may have been changed
  # since; the account ID has not.
  defp current_login(token, account) do
    case Client.request(:get, "/user/#{account.external_id}", auth: {:bearer, token}) do
      {:ok, %{body: %{"login" => login}}} ->
        {:ok, login}

      {:ok, _response} ->
        {:ok, account.login}

      {:error, %Error{status: 404} = error} ->
        {:error, Error.terminal(:access_lost, error.message, 404)}

      {:error, error} ->
        {:error, error}
    end
  end

  defp permission(%{"role_name" => role}) when is_binary(role), do: role
  defp permission(%{"permission" => permission}) when is_binary(permission), do: permission
  defp permission(_body), do: "none"

  @impl true
  def push_failure(output) do
    cond do
      Regex.match?(@rejected, output) -> {:terminal, :push_rejected}
      Regex.match?(@gone, output) -> {:terminal, :target_unreachable}
      true -> :transient
    end
  end

  @impl true
  def access_settings_url(%{installation_id: installation_id, target_account_type: type} = mirror) do
    if type == "organization" do
      owner = mirror.target_name |> String.split("/") |> List.first()
      "#{Config.web_url()}/organizations/#{owner}/settings/installations/#{installation_id}"
    else
      "#{Config.web_url()}/settings/installations/#{installation_id}"
    end
  end

  defp basic(token), do: Base.encode64("x-access-token:" <> Secret.reveal(token))

  defp same_login?(one, other) when is_binary(one) and is_binary(other),
    do: String.downcase(one) == String.downcase(other)

  defp same_login?(_one, _other), do: false
end
