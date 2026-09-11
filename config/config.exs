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
  # How often the background process refreshes cached `du` output.
  disk_usage_interval_ms: 60_000,
  # How often the background process prunes and repacks every repo.
  maintenance_interval_ms: 6 * 60 * 60 * 1000,
  # Number of per-ref old/new tips carried in a push widelog line.
  log_max_refs: 20,
  # The SSH listener. The host key directory defaults to `.pinha/ssh` under
  # the repo root, which the repo listing skips for not ending in `.git`.
  ssh_enabled: true,
  ssh_port: 2222,
  ssh_user: "git"

# Configure the endpoint
config :pinha, PinhaWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: PinhaWeb.ErrorHTML, json: PinhaWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Pinha.PubSub

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
