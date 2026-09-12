defmodule Pinha.Providers.AuthorizationsTest do
  @moduledoc "The consent round trip: who may finish one, once, and for how long."

  use Pinha.DataCase, async: false

  import Ecto.Query
  import Pinha.ProvidersFixtures

  alias Pinha.Providers.Authorization
  alias Pinha.Providers.Authorizations
  alias Pinha.Providers.GitHub
  alias Pinha.Repo
  alias Pinha.TestAuthorizationHandler

  @code "callback-code"
  @user_token "gho_useruseruseruseruseruseruseruseruser"

  setup do
    Process.register(self(), :authorization_probe)
    user = user_fixture()

    stub_github(%{
      {"POST", "/login/oauth/access_token"} => %{"access_token" => @user_token},
      {"DELETE", "/applications/Iv1.testclient/token"} => &revoked(&1)
    })

    %{user: user}
  end

  defp revoked(conn) do
    send(:authorization_probe, :revoked)
    Plug.Conn.send_resp(conn, 204, "")
  end

  defp start!(user, params \\ %{"return_to" => "/settings"}) do
    {:ok, url} = Authorizations.start(user, GitHub, TestAuthorizationHandler, params)
    %{"state" => state} = URI.decode_query(URI.parse(url).query)
    {url, state}
  end

  test "sends the browser to the provider with a state that is only stored hashed", %{
    user: user
  } do
    {url, state} = start!(user)

    assert url =~ "https://github.test/login/oauth/authorize"
    assert url =~ "client_id=Iv1.testclient"

    assert [authorization] = Repo.all(Authorization)
    assert authorization.user_id == user.id
    assert authorization.handler == "Pinha.TestAuthorizationHandler"
    assert authorization.state_hash == :crypto.hash(:sha256, state)
    refute authorization.state_hash == state
  end

  test "installing first is the same round trip", %{user: user} do
    {:ok, url} =
      Authorizations.start(user, GitHub, TestAuthorizationHandler, %{}, install: true)

    assert url =~ "https://github.test/apps/pinha-test/installations/new?state="
  end

  test "hands the handler the token, in a process runtime introspection cannot read", %{
    user: user
  } do
    {_url, state} = start!(user)

    assert {:ok, %{message: "handled", to: "/settings"}} =
             Authorizations.finish(GitHub, user, %{"state" => state, "code" => @code})

    assert_received {:handled, handled}
    assert handled.token == @user_token
    assert handled.user_id == user.id
    assert handled.dictionary == {:dictionary, []}

    # The token is revoked when the handler is done, and nothing is stored.
    assert_received :revoked
    assert Repo.all(Authorization) == []
  end

  test "a state is spent once", %{user: user} do
    {_url, state} = start!(user)

    assert {:ok, _result} =
             Authorizations.finish(GitHub, user, %{"state" => state, "code" => @code})

    assert Authorizations.finish(GitHub, user, %{"state" => state, "code" => @code}) ==
             {:refused, :unknown}
  end

  test "another user cannot finish an authorization in a victim's browser", %{user: user} do
    {_url, state} = start!(user)
    attacker = user_fixture()

    assert Authorizations.finish(GitHub, attacker, %{"state" => state, "code" => @code}) ==
             {:refused, :unknown}

    refute_received {:handled, _handled}

    # The one who started it can still finish it.
    assert {:ok, _result} =
             Authorizations.finish(GitHub, user, %{"state" => state, "code" => @code})
  end

  test "an expired authorization is refused", %{user: user} do
    {_url, state} = start!(user)
    expire(state)

    assert Authorizations.finish(GitHub, user, %{"state" => state, "code" => @code}) ==
             {:refused, :expired}

    refute_received {:handled, _handled}
    assert Repo.all(Authorization) == []
  end

  test "an unknown state is refused", %{user: user} do
    assert Authorizations.finish(GitHub, user, %{"state" => "nonsense", "code" => @code}) ==
             {:refused, :unknown}

    assert Authorizations.finish(GitHub, user, %{"code" => @code}) == {:refused, :unknown}
  end

  test "a declined authorization returns the user where they started", %{user: user} do
    {_url, state} = start!(user)

    assert Authorizations.finish(GitHub, user, %{
             "state" => state,
             "error" => "access_denied"
           }) == {:declined, "/settings"}

    refute_received {:handled, _handled}
  end

  test "prune_expired/0 clears what no callback will spend", %{user: user} do
    {_url, state} = start!(user)
    expire(state)

    assert Authorizations.prune_expired() == 1
    assert Repo.all(Authorization) == []
  end

  defp expire(state) do
    past = DateTime.utc_now() |> DateTime.add(-1, :second) |> DateTime.truncate(:second)
    hash = :crypto.hash(:sha256, state)

    Repo.update_all(from(a in Authorization, where: a.state_hash == ^hash),
      set: [expires_at: past]
    )
  end
end
