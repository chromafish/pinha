defmodule PinhaWeb.MirrorLiveTest do
  @moduledoc "The mirror pane's signal, and the changes that reach it live."

  use PinhaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Pinha.ProvidersFixtures

  alias Pinha.Mirroring

  setup %{user: user} do
    repo = seed_repo!("demo", [%{message: "first", files: %{"a.txt" => "a\n"}}], user)
    account = github_account_fixture(user)
    stub_github(Map.new([token_route(), repository_route()]))

    %{repo: repo, account: account}
  end

  test "a mirror that has never synced shows a neutral lamp", %{
    conn: conn,
    repo: repo,
    user: user,
    account: account
  } do
    mirror_fixture(repo, user, account)

    {:ok, view, html} = live_mirror(conn, repo, user)

    assert html =~ "signal-neutral"
    assert render(view) =~ "never synced"
  end

  test "a sync that starts turns the lamp amber and makes it pulse", %{
    conn: conn,
    repo: repo,
    user: user,
    account: account
  } do
    mirror_fixture(repo, user, account)

    {:ok, view, _html} = live_mirror(conn, repo, user)

    Mirroring.announce(repo.id, :started)

    html = render(view)
    assert html =~ "signal-warn"
    assert html =~ "signal-live"
    assert html =~ "syncing"
  end

  test "a mirror disabled elsewhere turns the lamp red without a reload", %{
    conn: conn,
    repo: repo,
    user: user,
    account: account
  } do
    mirror = mirror_fixture(repo, user, account)

    {:ok, view, html} = live_mirror(conn, repo, user)
    refute html =~ "signal-danger"

    {:ok, _mirror} = Mirroring.disable(mirror)

    html = render(view)
    assert html =~ "signal-danger"
    assert html =~ "switched off here"
  end

  defp live_mirror(conn, repo, user) do
    live_isolated(conn, PinhaWeb.MirrorLive,
      session: %{"repo" => repo.name, "user_uid" => user.uid, "csrf" => "token"}
    )
  end
end
