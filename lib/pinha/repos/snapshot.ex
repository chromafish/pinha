defmodule Pinha.Repos.Snapshot do
  @moduledoc """
  A repository's references at one moment: full reference name to object ID
  for `refs/heads/*` and `refs/tags/*`, plus the full names whose Jujutsu
  target is conflicted and therefore absent from `refs`.
  """

  @enforce_keys [:taken_at, :refs]
  defstruct [:taken_at, refs: %{}, conflicted: []]

  @type t :: %__MODULE__{
          taken_at: DateTime.t(),
          refs: %{String.t() => String.t()},
          conflicted: [String.t()]
        }
end
