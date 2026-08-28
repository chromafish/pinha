defmodule PinhaWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :pinha

  # Wraps the compiled pipeline so every request, matched or not, produces one
  # widelog line and one metrics observation once its body has been sent.
  @before_compile PinhaWeb.Observability

  @session_options [
    store: :cookie,
    key: "_pinha_key",
    signing_salt: "AUJtlgDg",
    same_site: "Lax"
  ]

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
