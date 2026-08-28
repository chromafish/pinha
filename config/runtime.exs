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

if config_env() == :prod do
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
