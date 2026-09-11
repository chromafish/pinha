import Config

# Tests drive a real git client over HTTP, so the server runs.
config :pinha, PinhaWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "3nciSawfbd3V7fTcfQzHjUssWRgG11Ea6IbaYzpYM/SO+HdJ10qr7hNTWmdvtprn",
  server: true

# The suite owns its own database, named by TEST_DATABASE_URL in
# config/runtime.exs.
config :pinha, Pinha.Repo,
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 5

config :pinha,
  repo_root: Path.expand("tmp/test_repos"),
  base_url: "http://127.0.0.1:4002",
  # The suite has no operator watching stdout, and minting a claim token at
  # boot would read the database outside the sandbox.
  claim_on_boot: false,
  # The suite asks the OS for a port so a running dev listener never collides
  # with it, and keeps host keys out of the repo roots tests throw away.
  ssh_port: 0,
  ssh_host_key_dir: Path.expand("tmp/test_ssh"),
  # Background processes stay idle during tests; the tests call them directly.
  disk_usage_interval_ms: 3_600_000,
  maintenance_interval_ms: 3_600_000,
  widelog: false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true
