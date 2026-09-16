defmodule PinhaWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :pinha

  # Wraps the compiled pipeline so every request, matched or not, produces one
  # widelog line once its body has been sent.
  @before_compile PinhaWeb.Observability

  # Without a `max_age` the cookie dies with the browser process, taking the
  # CSRF token with it while the session row behind it stays live. Kept at the
  # 60 days `Pinha.Accounts` gives a session, so the cookie and the row expire
  # together; inlined rather than read from `Accounts` to keep the endpoint
  # from taking a compile-time dependency on a context.
  @session_options [
    store: :cookie,
    key: "_pinha_key",
    signing_salt: "AUJtlgDg",
    same_site: "Lax",
    max_age: 60 * 24 * 60 * 60
  ]

  socket "/live", Phoenix.LiveView.Socket, websocket: [connect_info: [session: @session_options]]

  plug Plug.Static,
    at: "/",
    from: :pinha,
    gzip: not code_reloading?,
    only: PinhaWeb.static_paths(),
    raise_on_missing_only: code_reloading?

  if code_reloading? do
    socket "/phoenix/live_reload/socket", Phoenix.LiveReloader.Socket
    plug Phoenix.LiveReloader
    plug Phoenix.CodeReloader
  end

  plug Plug.RequestId
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]

  # Git RPC bodies are read by the transport itself, never by a parser.
  plug PinhaWeb.Plugs.GitAwareParsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library()

  plug Plug.MethodOverride
  plug Plug.Head
  plug Plug.Session, @session_options
  plug PinhaWeb.Router
end
