defmodule Pinha.Providers.Secret do
  @moduledoc """
  A credential for a provider, wrapped so it cannot be printed by accident.

  `inspect/1` renders `#Pinha.Providers.Secret<redacted>`, so a secret that
  ends up in a log line, a crash report, or an exception message shows up
  as that and nothing more. It has no JSON encoding, so it cannot be put into
  a job's arguments. The value is read with `reveal/1` at the one place that
  hands it to an HTTP request or a git process.
  """

  @enforce_keys [:value]
  defstruct [:value]

  @type t :: %__MODULE__{value: String.t()}

  @doc "Wraps a credential."
  @spec new(String.t()) :: t()
  def new(value) when is_binary(value), do: %__MODULE__{value: value}

  @doc "The credential itself."
  @spec reveal(t()) :: String.t()
  def reveal(%__MODULE__{value: value}), do: value
end
