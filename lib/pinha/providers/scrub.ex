defmodule Pinha.Providers.Scrub do
  @moduledoc """
  Removes credentials from text that came back from git or a provider before
  it is stored, logged, or shown.

  Known secrets are replaced wherever they appear, and so is anything shaped
  like a GitHub token, a JWT, an `Authorization` header, or credentials
  embedded in a URL, since git's stderr can echo any of them.
  """

  alias Pinha.Providers.Secret

  @redacted "[redacted]"

  @patterns [
    {~r/\b(?:gh[pousr]_[A-Za-z0-9_]{20,}|github_pat_[A-Za-z0-9_]{20,})/, @redacted},
    {~r/\beyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+/, @redacted},
    {~r/(authorization:\s*)(?:basic|bearer|token)\s+\S+/i, "\\1" <> @redacted},
    {~r/(\/\/)[^\/\s:@]+:[^\/\s@]+@/, "\\1" <> @redacted <> "@"}
  ]

  @doc "Text with every known secret and token-shaped string replaced."
  @spec scrub(String.t() | nil, [Secret.t()]) :: String.t() | nil
  def scrub(text, secrets \\ [])
  def scrub(nil, _secrets), do: nil

  def scrub(text, secrets) when is_binary(text) do
    text = Enum.reduce(secrets, text, &replace_secret/2)

    Enum.reduce(@patterns, text, fn {pattern, replacement}, text ->
      Regex.replace(pattern, text, replacement)
    end)
  end

  defp replace_secret(%Secret{} = secret, text) do
    value = Secret.reveal(secret)

    text
    |> String.replace(value, @redacted)
    |> String.replace(Base.encode64("x-access-token:" <> value), @redacted)
  end
end
