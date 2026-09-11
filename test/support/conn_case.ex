defmodule PinhaWeb.ConnCase do
  @moduledoc """
  This module defines the test case to be used by
  tests that require setting up a connection.

  Such tests rely on `Phoenix.ConnTest` and also
  import other functionality to make it easier
  to build common data structures and query the data layer.

  Tests share one repo root through the application environment, so they run
  serially. Every route but the sign-in surface needs a user, so the `conn`
  handed to a test is already signed in; reach for `build_conn/0` to see what
  a signed-out request gets.
  """

  use ExUnit.CaseTemplate

  alias Pinha.Accounts

  using do
    quote do
      # The default endpoint for testing
      @endpoint PinhaWeb.Endpoint

      use PinhaWeb, :verified_routes

      # Import conveniences for testing with connections
      import Plug.Conn
      import Phoenix.ConnTest
      import PinhaWeb.ConnCase
      import Pinha.RepoCase
      import Pinha.AccountsFixtures
      alias Pinha.Repos
    end
  end

  setup tags do
    # The endpoint answers in its own processes, so they share this test's
    # connection rather than checking out one of their own.
    owner = Ecto.Adapters.SQL.Sandbox.start_owner!(Pinha.Repo, shared: not tags[:async])
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(owner) end)

    user = Pinha.AccountsFixtures.user_fixture()
    Process.put(:pinha_test_user, user)

    {:ok,
     conn: log_in_user(Phoenix.ConnTest.build_conn(), user),
     user: user,
     root: Pinha.RepoCase.setup_root!()}
  end

  @doc "Gives `conn` a live session for `user`, skipping the passkey ceremony."
  def log_in_user(conn, user) do
    conn
    |> Plug.Test.init_test_session(%{})
    |> Plug.Conn.put_session("user_token", Accounts.create_session(user))
  end

  @doc "A fresh connection signed in as the test's user."
  def signed_in_conn do
    user = Process.get(:pinha_test_user) || raise "no user in this test"
    log_in_user(Phoenix.ConnTest.build_conn(), user)
  end

  @doc """
  A URL carrying HTTP Basic credentials, the way a git remote does.

  The email is percent-encoded because it contains the `@` that separates
  credentials from the host.
  """
  def authenticated_url(user, path) do
    secret = Pinha.AccountsFixtures.token_fixture(user)
    uri = URI.parse(Pinha.RepoCase.base_url())

    %{uri | userinfo: URI.encode_www_form(user.email) <> ":" <> secret}
    |> URI.to_string()
    |> Kernel.<>(path)
  end
end
