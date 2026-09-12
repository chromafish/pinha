defmodule Pinha.Providers.Error do
  @moduledoc """
  A failure while talking to a provider.

  It carries the HTTP status, when there was one, and the provider's message,
  never a request, a response, or headers, so it is safe to log and to show
  to a person. `kind` tells a terminal failure, which will not go away by
  trying again, from a transient one. `reason` names what a terminal failure
  means to the feature, such as `:installation_removed`.
  """

  defexception [:message, :status, kind: :transient, reason: nil]

  @type kind :: :terminal | :transient
  @type t :: %__MODULE__{
          message: String.t(),
          status: pos_integer() | nil,
          kind: kind(),
          reason: atom() | nil
        }

  @doc "A failure that trying again may fix."
  @spec transient(String.t(), pos_integer() | nil) :: t()
  def transient(message, status \\ nil),
    do: %__MODULE__{kind: :transient, message: message, status: status}

  @doc "A failure that stays until something changes, with what it means."
  @spec terminal(atom(), String.t(), pos_integer() | nil) :: t()
  def terminal(reason, message, status \\ nil),
    do: %__MODULE__{kind: :terminal, reason: reason, message: message, status: status}
end
