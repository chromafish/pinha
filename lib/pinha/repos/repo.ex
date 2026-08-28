defmodule Pinha.Repos.Repo do
  @moduledoc "A bare repository on disk."

  @enforce_keys [:name, :dir]
  defstruct [:name, :dir, :description]

  @type t :: %__MODULE__{name: String.t(), dir: String.t(), description: String.t() | nil}
end
