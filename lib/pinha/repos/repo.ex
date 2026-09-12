defmodule Pinha.Repos.Repo do
  @moduledoc """
  A repository on disk, with a persisted Git or Jujutsu model.

  `id` is the `pinha.id` entry: `r_` and 128 random bits in lowercase base32,
  minted at create. A repository created before the field existed has none
  until something that keys database rows by it mints one.

  `kind` is the `pinha.kind` entry. Repositories created before that marker
  existed are Git repositories. `owner_uid` is the `pinha.owner` entry of the repo's own git config: the
  `uid` of the user who may push. It lives in git rather than in the database
  so a repo restored from a filesystem copy carries its owner with it, and it
  is nil for a repo created by hand with `git init --bare`.
  """

  @enforce_keys [:name, :dir]
  defstruct [:name, :dir, :id, :description, :owner_uid, kind: :git]

  @type t :: %__MODULE__{
          name: String.t(),
          dir: String.t(),
          id: String.t() | nil,
          description: String.t() | nil,
          owner_uid: String.t() | nil,
          kind: :git | :jj
        }
end
