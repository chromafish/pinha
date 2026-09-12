defmodule Pinha.Ceremony do
  @moduledoc """
  The passkey ceremonies, driven through a real page.

  These helpers fill the form the server rendered and submit it, so
  `webauthn.js`, the CSRF header, the session cookie and both endpoints are
  exercised rather than reimplemented. The authenticator comes from
  `Pinha.Browser`.
  """

  alias Pinha.Browser

  @doc "Opens a page with a virtual authenticator attached to it."
  @spec open!(pid()) :: String.t()
  def open!(browser) do
    %{"targetId" => target} = Browser.call!(browser, "Target.createTarget", %{url: "about:blank"})

    %{"sessionId" => session} =
      Browser.call!(browser, "Target.attachToTarget", %{targetId: target, flatten: true})

    Browser.call!(browser, "Page.enable", %{}, session)
    Browser.call!(browser, "Runtime.enable", %{}, session)
    Browser.call!(browser, "WebAuthn.enable", %{}, session)

    Browser.call!(
      browser,
      "WebAuthn.addVirtualAuthenticator",
      %{
        options: %{
          protocol: "ctap2",
          transport: "internal",
          hasResidentKey: true,
          hasUserVerification: true,
          isUserVerified: true,
          automaticPresenceSimulation: true
        }
      },
      session
    )

    session
  end

  @doc "Navigates to `path` and waits for the document to finish loading."
  @spec visit!(pid(), String.t(), String.t()) :: :ok
  def visit!(browser, session, path) do
    Browser.call!(browser, "Page.navigate", %{url: url(path)}, session)
    await(browser, session, "document.readyState === 'complete'", "#{path} never loaded")
  end

  @doc "Signs up, filling the rendered form and pressing its button."
  @spec sign_up!(pid(), String.t(), keyword()) :: :ok
  def sign_up!(browser, session, fields) do
    visit!(browser, session, "/signup")

    for {name, value} <- fields do
      evaluate!(browser, session, """
      document.querySelector('#signup [name=#{name}]').value = #{Jason.encode!(value)}
      """)
    end

    submit!(browser, session, "#signup")
  end

  @doc "Signs in with whatever passkey the authenticator is holding."
  @spec sign_in!(pid(), String.t()) :: :ok
  def sign_in!(browser, session) do
    visit!(browser, session, "/signin")
    submit!(browser, session, "#signin")
  end

  @doc "Signs out, the way the settings page does."
  @spec sign_out!(pid(), String.t()) :: :ok
  def sign_out!(browser, session) do
    visit!(browser, session, "/settings")

    evaluate!(browser, session, """
    (() => {
      const form = document.createElement("form");
      form.method = "post";
      form.action = "/signout";
      for (const [name, value] of [
        ["_method", "delete"],
        ["_csrf_token", document.querySelector("meta[name=csrf-token]").content]
      ]) {
        const field = document.createElement("input");
        field.name = name;
        field.value = value;
        form.appendChild(field);
      }
      document.body.appendChild(form);
      form.submit();
    })()
    """)

    await(browser, session, "location.pathname === '/signin'", "sign-out never landed")
  end

  @doc "The status line the page shows when a ceremony refuses."
  @spec status(pid(), String.t()) :: String.t()
  def status(browser, session) do
    evaluate!(browser, session, "document.querySelector('[data-status]')?.textContent ?? ''")
  end

  @doc "The path the browser is currently on."
  @spec path(pid(), String.t()) :: String.t()
  def path(browser, session), do: evaluate!(browser, session, "location.pathname")

  @doc "The page's visible text, for asserting on what actually rendered."
  @spec text(pid(), String.t()) :: String.t()
  def text(browser, session), do: evaluate!(browser, session, "document.body.innerText")

  # Submitting dispatches the event webauthn.js listens for, rather than
  # clicking, so the ceremony runs whether or not the button has focus.
  defp submit!(browser, session, form) do
    evaluate!(browser, session, """
    document.querySelector("#{form}").dispatchEvent(
      new Event("submit", { bubbles: true, cancelable: true })
    )
    """)

    # A ceremony either navigates away on success or writes its refusal into
    # the status line, which webauthn.js has already filled with the waiting
    # message by the time the authenticator is asked.
    await(
      browser,
      session,
      """
      (() => {
        const status = document.querySelector("[data-status]")?.textContent ?? "";
        const waiting = status === "" || status === "Waiting for your authenticator.";
        const onForm = ["/signup", "/signin"].includes(location.pathname);
        return !onForm || !waiting;
      })()
      """,
      "the ceremony neither finished nor reported why"
    )
  end

  defp evaluate!(browser, session, expression) do
    result =
      Browser.call!(
        browser,
        "Runtime.evaluate",
        %{expression: expression, returnByValue: true, awaitPromise: true},
        session
      )

    case result do
      %{"exceptionDetails" => details} -> raise "page raised: #{inspect(details)}"
      # An expression evaluated for its effect answers with no value at all.
      %{"result" => value} -> Map.get(value, "value")
    end
  end

  defp await(browser, session, expression, message, attempts \\ 100) do
    cond do
      evaluate!(browser, session, expression) == true ->
        :ok

      attempts == 0 ->
        raise "#{message} (still: #{path(browser, session)} #{status(browser, session)})"

      true ->
        Process.sleep(50)
        await(browser, session, expression, message, attempts - 1)
    end
  end

  # Chromium refuses an IP address as a WebAuthn relying party, so the browser
  # reaches the test endpoint by the name the challenge will be built from.
  defp url(path), do: Pinha.Config.base_url() <> path
end
