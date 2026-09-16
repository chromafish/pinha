# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.
import Config

config :pinha,
  ecto_repos: [Pinha.Repo],
  # Root directory holding the bare repositories. Overridden at runtime.
  repo_root: Path.expand("priv/repos"),
  # Public base URL advertised in the UI for clone commands.
  base_url: "http://localhost:4000",
  git_bin: "git",
  # How often the background process prunes and repacks every repo.
  maintenance_interval_ms: 6 * 60 * 60 * 1000,
  # Number of per-ref old/new tips carried in a push widelog line.
  log_max_refs: 20,
  # A warm browser session stays in this node long enough to take Neon out of
  # ordinary navigation. Postgres is consulted again after the bounded TTL.
  session_cache_ttl_ms: 60_000,
  session_cache_sweep_interval_ms: 60_000,
  # The SSH listener. The host key directory defaults to `.pinha/ssh` under
  # the repo root, which the repo listing skips for not ending in `.git`.
  ssh_enabled: true,
  ssh_port: 2222,
  ssh_user: "git",
  # The forges Pinha integrates with, and what listens to their events. A
  # provider the operator has not configured offers no capabilities.
  providers: [Pinha.Providers.GitHub],
  provider_subscribers: [Pinha.Providers.Accounts, Pinha.Mirroring]

# Background work: mirror syncs and provider events. Jobs run once, so a
# failure waits for a person rather than retrying on its own.
config :pinha, Oban,
  repo: Pinha.Repo,
  # Neon's pooled endpoint is PgBouncer in transaction mode, which cannot
  # hold the session a `LISTEN` notifier needs.
  notifier: Oban.Notifiers.PG,
  queues: [mirrors: 4, providers: 4],
  pruner: [max_age: {7, :days}],
  cron: [crontab: [{"17 * * * *", Pinha.Providers.PruneWorker}]]

# Configure the endpoint
config :pinha, PinhaWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: PinhaWeb.ErrorHTML, json: PinhaWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Pinha.PubSub,
  live_view: [signing_salt: "sxDykbENXRN7zHOGRHBLdl17X01IfKSo"]

# pinha writes one canonical JSON line per request. Phoenix's own request
# logger would print two more next to it, unstructured. The telemetry events
# it listens to stay on: the traces are built from them.
config :phoenix, :logger, false

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# The browser bundle. Dependencies resolve against deps/, so the LiveView
# client tracks the versions in mix.lock with no package manager involved.
config :esbuild,
  version: "0.25.5",
  pinha: [
    args: ~w(js/app.js --bundle --target=es2020 --outdir=../priv/static/assets/js),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => Path.expand("../deps", __DIR__)}
  ]

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
