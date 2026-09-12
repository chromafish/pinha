defmodule PinhaWeb.PasskeyCeremonyTest do
  @moduledoc """
  Sign-up and sign-in through a browser, end to end.

  The rest of the suite gives a connection a session directly, since an
  assertion cannot be produced from Elixir. These tests use a CDP virtual
  authenticator instead, so the ceremonies themselves are covered.

  Tagged `:ceremony`. Run `mix test --exclude ceremony` on a machine without a
  browser.
  """

  use PinhaWeb.ConnCase, async: false

  @moduletag :ceremony

  alias Pinha.Accounts
  alias Pinha.Browser
  alias Pinha.Ceremony

  # The relying party is the host of the base URL, and Chromium refuses an IP
  # address as one ("SecurityError: This is an invalid domain"), so the browser
  # reaches the test endpoint by name rather than by the address it binds.
  defp browser_base_url, do: String.replace(base_url(), "127.0.0.1", "localhost")

  setup do
    executable =
      case Browser.find() do
        {:ok, executable} -> executable
        :error -> flunk(Browser.install_hint())
      end

    previous = Application.get_env(:pinha, :base_url)
    Application.put_env(:pinha, :base_url, browser_base_url())
    on_exit(fn -> Application.put_env(:pinha, :base_url, previous) end)

    browser = start_supervised!({Browser, executable})

    # Registered after ConnCase's, so it runs before it: the page has to stop
    # making requests before the sandbox owner it borrows a connection from
    # goes away.
    on_exit(fn -> if Process.alive?(browser), do: Browser.stop(browser) end)

    %{browser: browser, page: Ceremony.open!(browser)}
  end

  test "a passkey registered on an invite signs its owner back in", context do
    %{browser: browser, page: page, user: admin} = context
    invite = invite_fixture(admin)

    Ceremony.sign_up!(browser, page,
      email: "newcomer@example.com",
      invite: invite,
      label: "virtual key"
    )

    assert Ceremony.path(browser, page) == "/",
           "sign-up did not land: #{Ceremony.status(browser, page)}"

    assert {:ok, user} = Accounts.fetch_user_by_email("newcomer@example.com")
    assert [credential] = Accounts.list_credentials(user)
    assert credential.label == "virtual key"
    refute credential.last_used_at

    Ceremony.sign_out!(browser, page)

    Ceremony.sign_in!(browser, page)

    assert Ceremony.path(browser, page) == "/",
           "sign-in did not land: #{Ceremony.status(browser, page)}"

    # The repository list names whoever is signed in, so this is the session
    # landing on the right account rather than merely existing.
    assert Ceremony.text(browser, page) =~ "newcomer@example.com"

    # Set by record_authentication/3, so the assertion verified and named a
    # user the database holds.
    assert [used] = Accounts.list_credentials(user)
    assert used.last_used_at
  end

  test "the handle the authenticator kept is the handle the server stored", context do
    %{browser: browser, page: page, user: admin} = context
    invite = invite_fixture(admin)

    Ceremony.sign_up!(browser, page,
      email: "handled@example.com",
      invite: invite,
      label: "virtual key"
    )

    assert {:ok, user} = Accounts.fetch_user_by_email("handled@example.com")
    assert {:ok, same} = Accounts.fetch_user_by_handle(user.handle)
    assert same.id == user.id

    Ceremony.sign_out!(browser, page)
    Ceremony.sign_in!(browser, page)

    assert Ceremony.path(browser, page) == "/",
           "the stored handle is not the one the authenticator replays: " <>
             Ceremony.status(browser, page)
  end

  test "a signed-out browser is refused when it holds no passkey", context do
    %{browser: browser, page: page} = context

    Ceremony.sign_in!(browser, page)

    assert Ceremony.path(browser, page) == "/signin"
    assert Ceremony.status(browser, page) != ""
  end
end
