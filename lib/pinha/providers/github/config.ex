defmodule Pinha.Providers.GitHub.Config do
  @moduledoc """
  The operator's GitHub App settings, from the `Pinha.Providers.GitHub`
  application environment.

  The provider is configured only when the app ID and slug, client ID and
  secret, private key, and webhook secret are all present. The URLs default
  to GitHub's and are overridden only by the suite.
  """

  @required [:app_id, :app_slug, :client_id, :client_secret, :private_key, :webhook_secret]

  @doc "Whether every required setting is present."
  @spec configured?() :: boolean()
  def configured? do
    env = env()
    Enum.all?(@required, &present?(Keyword.get(env, &1)))
  end

  def app_id, do: fetch(:app_id)
  def app_slug, do: fetch(:app_slug)
  def client_id, do: fetch(:client_id)
  def client_secret, do: fetch(:client_secret)
  def private_key, do: fetch(:private_key)
  def webhook_secret, do: fetch(:webhook_secret)

  @doc "Base URL of the REST API."
  def api_url, do: Keyword.get(env(), :api_url, "https://api.github.com")

  @doc "Base URL of the web pages: consent, installation, and OAuth endpoints."
  def web_url, do: Keyword.get(env(), :web_url, "https://github.com")

  @doc "Base URL git pushes to, joined with a repository's full name."
  def git_url, do: Keyword.get(env(), :git_url, "https://github.com")

  @doc "Extra `Req` options, which is how the suite plugs in its stub."
  def req_options, do: Keyword.get(env(), :req_options, [])

  defp fetch(key), do: Keyword.get(env(), key) || ""

  defp env, do: Application.get_env(:pinha, Pinha.Providers.GitHub, [])

  defp present?(value), do: is_binary(value) and String.trim(value) != ""
end
