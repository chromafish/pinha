import Config

config :pinha, repo_root: Path.expand("tmp/repos")

config :pinha, PinhaWeb.Endpoint,
  # Binding to loopback prevents access from other machines.
  http: [ip: {127, 0, 0, 1}],
  check_origin: false,
  code_reloader: true,
  debug_errors: true,
  secret_key_base: "LCnlwZFXdEJc7xl1F1zJ/io8UbsJ+4in4GuDZFnmyMxVFtz8PgmfxGNYZl8mZrIs",
  watchers: []

config :pinha, PinhaWeb.Endpoint,
  live_reload: [
    patterns: [
      ~r"priv/static/assets/.*\.(css|js)$"E,
      ~r"lib/pinha_web/(controllers|components)/.*\.(ex|heex)$"E,
      ~r"lib/pinha_web/router\.ex$"E
    ]
  ]

# Do not include metadata nor timestamps in development logs
config :logger, :default_formatter, format: "[$level] $message\n"

config :phoenix, :stacktrace_depth, 20
config :phoenix, :plug_init_mode, :runtime
