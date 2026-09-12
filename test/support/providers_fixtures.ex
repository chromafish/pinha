defmodule Pinha.ProvidersFixtures do
  @moduledoc """
  Linked accounts, mirrors, and a stubbed GitHub for tests.

  Nothing here reaches GitHub: `Req.Test` answers every API call, and a
  mirror target is a bare repository on disk reached over `file://`.
  """

  import ExUnit.Callbacks, only: [on_exit: 1]

  alias Pinha.Mirroring.Mirror
  alias Pinha.Providers.Accounts
  alias Pinha.Providers.GitHub
  alias Pinha.Repo

  @doc "Links a GitHub identity to `user`."
  def github_account_fixture(user, attrs \\ %{}) do
    {:ok, account} =
      Accounts.link(user, "github", %{
        external_id: Map.get(attrs, :external_id, "4711"),
        login: Map.get(attrs, :login, "octo")
      })

    account
  end

  @doc "A mirror row, as a connect would have written it."
  def mirror_fixture(repo, user, account, attrs \\ %{}) do
    %Mirror{
      repo_id: repo.id,
      repo_name: repo.name,
      provider: "github",
      installation_id: "99",
      target_id: "1234",
      target_name: "octo/demo",
      target_url: "https://github.test/octo/demo",
      target_account_type: "user",
      connected_by_user_id: user.id,
      provider_account_id: account.id,
      state: "active"
    }
    |> struct!(attrs)
    |> Repo.insert!()
  end

  @doc """
  A bare repository standing in for the target on GitHub, and the `git_url`
  that reaches it.
  """
  def github_target!(full_name \\ "octo/demo") do
    root = Path.join(System.tmp_dir!(), "pinha-target-" <> random())
    dir = Path.join(root, full_name <> ".git")
    File.mkdir_p!(dir)
    Pinha.RepoCase.git!(File.cwd!(), ["init", "--bare", "--quiet", dir])

    put_github_env(git_url: "file://" <> root)
    on_exit(fn -> File.rm_rf(root) end)

    %{dir: dir, root: root, full_name: full_name}
  end

  @doc "Overrides GitHub settings for one test."
  def put_github_env(options) do
    previous = Application.get_env(:pinha, GitHub)
    Application.put_env(:pinha, GitHub, Keyword.merge(previous, options))
    on_exit(fn -> Application.put_env(:pinha, GitHub, previous) end)
    :ok
  end

  @doc """
  Answers GitHub's API from `routes`, a map of `{method, path}` to a function
  of the connection, or to a body to send as JSON.
  """
  def stub_github(routes) do
    Req.Test.stub(GitHub, fn conn ->
      case Map.fetch(routes, {conn.method, conn.request_path}) do
        {:ok, fun} when is_function(fun, 1) ->
          fun.(conn)

        {:ok, body} ->
          Req.Test.json(conn, body)

        :error ->
          conn
          |> Plug.Conn.put_status(404)
          |> Req.Test.json(%{"message" => "no stub for #{conn.method} #{conn.request_path}"})
      end
    end)
  end

  @doc "What a scoped installation token call answers, with the token it hands out."
  def token_route(token \\ "ghs_0123456789abcdefghijklmnopqrstuvwxyz"),
    do: {{"POST", "/app/installations/99/access_tokens"}, %{"token" => token}}

  @doc "What looking the target repository up answers."
  def repository_route(full_name \\ "octo/demo", id \\ "1234") do
    {{"GET", "/repositories/#{id}"},
     %{
       "id" => String.to_integer(id),
       "full_name" => full_name,
       "html_url" => "https://github.test/#{full_name}"
     }}
  end

  defp random, do: Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
end
