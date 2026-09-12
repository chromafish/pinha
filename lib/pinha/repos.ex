defmodule Pinha.Repos do
  @moduledoc """
  Repository lifecycle on disk. Git is the source of truth: there is no
  metadata store, so every function here reads the repo root directly.

  Ownership follows the same rule. A repo records the `uid` of whoever may
  push to it as `pinha.owner` in its own config, which is read here straight
  from the config file: a listing of fifty repos is fifty small file reads
  rather than fifty `git` processes.
  """

  alias Pinha.Accounts
  alias Pinha.Accounts.User
  alias Pinha.Config
  alias Pinha.Git
  alias Pinha.Repos.Repo

  @name_regex ~r/\A[A-Za-z0-9][A-Za-z0-9._-]{0,63}\z/
  @default_description "Unnamed repository; edit this file 'description' to name the repository."

  @doc """
  Strips an optional `.git` suffix and validates the remaining name.

  Names are a single path segment: no slashes, no leading dot, no `..`.
  """
  @spec normalize_name(String.t()) :: {:ok, String.t()} | {:error, :invalid_name}
  def normalize_name(name) when is_binary(name) do
    name = String.trim(name)

    name =
      if String.ends_with?(name, ".git"),
        do: binary_part(name, 0, byte_size(name) - 4),
        else: name

    if name != ".." and Regex.match?(@name_regex, name) do
      {:ok, name}
    else
      {:error, :invalid_name}
    end
  end

  def normalize_name(_), do: {:error, :invalid_name}

  @doc "Absolute path of `<name>.git` under the repo root."
  @spec dir(String.t()) :: String.t()
  def dir(name), do: Path.join(Config.repo_root(), name <> ".git")

  @doc """
  Every child directory ending in `.git` that is a valid bare repository.

  Non-repo directories are skipped.
  """
  @spec list() :: [Repo.t()]
  def list do
    case File.ls(Config.repo_root()) do
      {:ok, entries} ->
        entries
        |> Enum.filter(&String.ends_with?(&1, ".git"))
        |> Enum.map(&binary_part(&1, 0, byte_size(&1) - 4))
        |> Enum.filter(&match?({:ok, _}, normalize_name(&1)))
        |> Enum.filter(&bare_repo?(dir(&1)))
        |> Enum.sort()
        |> Enum.map(&load(&1))

      {:error, _} ->
        []
    end
  end

  @doc """
  Looks up one repository by name, with or without the `.git` suffix.

  A directory that exists but is not a valid bare repository reports
  `:invalid_repo`; nothing is repaired on the way.
  """
  @spec fetch(String.t()) ::
          {:ok, Repo.t()} | {:error, :invalid_name | :invalid_repo | :not_found}
  def fetch(name) do
    with {:ok, name} <- normalize_name(name) do
      dir = dir(name)

      cond do
        bare_repo?(dir) -> {:ok, load(name)}
        File.exists?(dir) -> {:error, :invalid_repo}
        true -> {:error, :not_found}
      end
    end
  end

  @doc """
  Creates `<name>.git`, owned by `user`.

  Serialized through `Pinha.Repos.Creator`, so concurrent creates of the same
  name never race: the loser gets `{:error, :exists}`. The owner is written
  before the directory is moved into place, so a repo is never listed unowned.
  """
  @spec create(String.t(), User.t() | nil) ::
          {:ok, Repo.t()} | {:error, :invalid_name | :exists | :failed}
  def create(name, owner \\ nil) do
    with {:ok, name} <- normalize_name(name) do
      Pinha.Repos.Creator.create(name, owner && owner.uid)
    end
  end

  @doc """
  Who may push to this repo.

  Every user reads every repo, so there is no read side to this. Writing is
  the owner and admins; a repo with no owner, made by hand or left behind by a
  deleted user, is writable by admins alone until one assigns an owner.
  """
  @spec writable_by?(Repo.t(), User.t() | nil) :: boolean()
  def writable_by?(_repo, nil), do: false
  def writable_by?(_repo, %User{admin: true}), do: true
  def writable_by?(%Repo{owner_uid: nil}, _user), do: false
  def writable_by?(%Repo{owner_uid: uid}, %User{uid: uid}), do: true
  def writable_by?(_repo, _user), do: false

  @doc "The user who owns this repo, when the `uid` still names one."
  @spec owner(Repo.t()) :: {:ok, User.t()} | :error
  def owner(%Repo{owner_uid: nil}), do: :error
  def owner(%Repo{owner_uid: uid}), do: Accounts.fetch_user_by_uid(uid)

  @doc """
  Hands a repo to the user with this username.

  Written with `git config`, so the repo on disk stays the record of who owns
  it. Called from the repo page and from the release console.
  """
  @spec set_owner(String.t(), String.t()) ::
          {:ok, Repo.t()}
          | {:error, :invalid_name | :invalid_repo | :not_found | :no_such_user | :failed}
  def set_owner(name, username) when is_binary(username) do
    with {:ok, repo} <- fetch(name),
         {:ok, user} <- fetch_user(username) do
      case Git.run(repo.dir, ["config", "pinha.owner", user.uid]) do
        {:ok, _} -> {:ok, %{repo | owner_uid: user.uid}}
        {:error, _} -> {:error, :failed}
      end
    end
  end

  defp fetch_user(username) do
    case Accounts.fetch_user_by_username(username) do
      {:ok, user} -> {:ok, user}
      :error -> {:error, :no_such_user}
    end
  end

  @doc """
  Renames `<name>.git` out of the listing, then removes it in the background.

  New requests stop resolving the repo immediately while in-flight ones keep
  reading the renamed directory until they finish.
  """
  @spec delete(String.t()) :: :ok | {:error, :invalid_name | :not_found | :failed}
  def delete(name) do
    with {:ok, name} <- normalize_name(name) do
      Pinha.Repos.Creator.delete(name)
    end
  end

  @doc "True when the directory looks like a bare repository."
  @spec bare_repo?(String.t()) :: boolean()
  def bare_repo?(dir) do
    File.regular?(Path.join(dir, "HEAD")) and
      File.dir?(Path.join(dir, "objects")) and
      File.dir?(Path.join(dir, "refs"))
  end

  @doc "Contents of the `description` file, or nil when missing or still the git default."
  @spec description(String.t()) :: String.t() | nil
  def description(dir) do
    case File.read(Path.join(dir, "description")) do
      {:ok, text} ->
        text = String.trim(text)

        if text == "" or String.starts_with?(text, @default_description) do
          nil
        else
          text
        end

      {:error, _} ->
        nil
    end
  end

  @doc """
  The `pinha.owner` entry of a repo's config, read from the file itself.

  git's config format is an INI with tab-indented entries; only this one key
  is looked for, and anything unreadable reads as no owner, which falls back
  to admins.
  """
  @spec owner_uid(String.t()) :: String.t() | nil
  def owner_uid(dir) do
    case File.read(Path.join(dir, "config")) do
      {:ok, text} -> find_owner(text)
      {:error, _} -> nil
    end
  end

  defp find_owner(text) do
    text
    |> String.split("\n")
    |> Enum.reduce_while({nil, nil}, fn line, {section, _} = acc ->
      case String.trim(line) do
        "[" <> rest ->
          {:cont, {rest |> String.trim_trailing("]") |> String.downcase(), nil}}

        entry ->
          case {section, String.split(entry, "=", parts: 2)} do
            {"pinha", [key, value]} ->
              if String.trim(key) |> String.downcase() == "owner" do
                {:halt, {section, String.trim(value)}}
              else
                {:cont, acc}
              end

            _ ->
              {:cont, acc}
          end
      end
    end)
    |> elem(1)
    |> case do
      nil -> nil
      "" -> nil
      uid -> uid
    end
  end

  defp load(name) do
    dir = dir(name)
    %Repo{name: name, dir: dir, description: description(dir), owner_uid: owner_uid(dir)}
  end
end
