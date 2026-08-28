defmodule Pinha.Repos do
  @moduledoc """
  Repository lifecycle on disk. Git is the source of truth: there is no
  metadata store, so every function here reads the repo root directly.
  """

  alias Pinha.Config
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
  Creates `<name>.git`.

  Serialized through `Pinha.Repos.Creator`, so concurrent creates of the same
  name never race: the loser gets `{:error, :exists}`.
  """
  @spec create(String.t()) :: {:ok, Repo.t()} | {:error, :invalid_name | :exists | :failed}
  def create(name) do
    with {:ok, name} <- normalize_name(name) do
      Pinha.Repos.Creator.create(name)
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

  defp load(name) do
    dir = dir(name)
    %Repo{name: name, dir: dir, description: description(dir)}
  end
end
