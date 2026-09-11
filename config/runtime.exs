import Config

# Executed for all environments, including releases, after compilation and
# before the system starts. The three operator knobs are the repo root, the
# listen address, and the public base URL.

if System.get_env("PHX_SERVER") do
  config :pinha, PinhaWeb.Endpoint, server: true
end

if repo_root = System.get_env("PINHA_REPO_ROOT") do
  config :pinha, repo_root: Path.expand(repo_root)
end

if System.get_env("PINHA_SIGNUP_OPEN") in ~w(1 true yes) do
  config :pinha, signup_open: true
end

if base_url = System.get_env("PINHA_BASE_URL") do
  config :pinha, base_url: String.trim_trailing(base_url, "/")
end

listen_ip =
  case System.get_env("PINHA_LISTEN_ADDRESS") do
    nil ->
      nil

    address ->
      case :inet.parse_address(String.to_charlist(address)) do
        {:ok, ip} -> ip
        {:error, _} -> raise "PINHA_LISTEN_ADDRESS is not a valid IP address: #{address}"
      end
  end

# The test endpoint keeps the port from config/test.exs so a running dev
# server never collides with the suite.
if config_env() != :test do
  port = String.to_integer(System.get_env("PORT", "4000"))

  http_options =
    case listen_ip do
      nil -> [port: port]
      ip -> [ip: ip, port: port]
    end

  config :pinha, PinhaWeb.Endpoint, http: http_options
end

# Every environment reaches the same Neon project, so the connection rules
# live here once rather than in three config files. `mix test` reads
# TEST_DATABASE_URL so a run cannot touch the database being developed
# against.
database_url =
  if config_env() == :test do
    System.get_env("TEST_DATABASE_URL")
  else
    System.get_env("DATABASE_URL")
  end

if config_env() == :prod and is_nil(database_url) do
  raise """
  environment variable DATABASE_URL is missing.
  Neon shows it on the project dashboard, in the form
  postgresql://user:password@ep-name.region.aws.neon.tech/pinha?sslmode=require
  """
end

if database_url do
  uri = URI.parse(database_url)
  db_host = uri.host || ""
  remote? = db_host not in ["localhost", "127.0.0.1", "::1", ""]

  repo_options =
    [
      # Neon's dashboard appends sslmode and channel_binding to the URL it
      # hands out. Postgrex takes neither as an option, and TLS is configured
      # below, so the query is dropped rather than passed through.
      url: URI.to_string(%{uri | query: nil}),
      # Neon's pooled endpoint is PgBouncer in transaction mode, which cannot
      # hold named prepared statements.
      prepare: if(String.contains?(db_host, "-pooler."), do: :unnamed, else: :named),
      # `mix ecto.create` connects here to issue CREATE DATABASE. A Neon
      # branch may not carry a `postgres` database, so name one it does.
      maintenance_database: System.get_env("MAINTENANCE_DATABASE", "postgres")
    ] ++
      if remote? do
        # Verify the chain against the OS trust store rather than trusting
        # whatever answers on the other end.
        [
          ssl: [
            verify: :verify_peer,
            cacerts: :public_key.cacerts_get(),
            server_name_indication: to_charlist(db_host),
            customize_hostname_check: [
              match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
            ]
          ]
        ]
      else
        []
      end

  config :pinha, Pinha.Repo, repo_options
end

if config_env() == :prod do
  config :pinha, Pinha.Repo, pool_size: String.to_integer(System.get_env("POOL_SIZE", "5"))

  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  base_url = Application.get_env(:pinha, :base_url)
  %URI{scheme: scheme, host: host} = URI.parse(base_url)

  config :pinha, PinhaWeb.Endpoint,
    url: [host: host || "localhost", scheme: scheme || "http", port: URI.parse(base_url).port],
    secret_key_base: secret_key_base
end
