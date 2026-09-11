defmodule Pinha.Repos.Repo do
  @moduledoc """
  A bare repository on disk.

  `owner_uid` is the `pinha.owner` entry of the repo's own git config: the
  `uid` of the user who may push. It lives in git rather than in the database
  so a repo restored from a filesystem copy carries its owner with it, and it
  is nil for a repo created by hand with `git init --bare`.
  """

  @enforce_keys [:name, :dir]
  defstruct [:name, :dir, :description, :owner_uid]

  @type t :: %__MODULE__{
          name: String.t(),
          dir: String.t(),
          description: String.t() | nil,
          owner_uid: String.t() | nil
        }
end
