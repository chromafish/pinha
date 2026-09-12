defmodule Pinha.RepoCase do
  @moduledoc """
  Gives each test its own repo root and helpers for seeding bare repositories
  with real commits, including Jujutsu `change-id` trailers.
  """

  use ExUnit.CaseTemplate

  alias Pinha.Repos

  using do
    quote do
      import Pinha.RepoCase
      alias Pinha.Repos
    end
  end

  setup do
    {:ok, root: setup_root!()}
  end

  @doc """
  Points the application at a fresh repo root for the duration of one test.
  """
  def setup_root! do
    root = Path.join(System.tmp_dir!(), "pinha-test-" <> random())
    File.mkdir_p!(root)
    previous = Application.get_env(:pinha, :repo_root)
    Application.put_env(:pinha, :repo_root, root)

    ExUnit.Callbacks.on_exit(fn ->
      Application.put_env(:pinha, :repo_root, previous)
      File.rm_rf(root)
    end)

    root
  end

  @doc "Creates a bare repository through the service itself, owned by `owner`."
  def create_repo!(name, owner \\ nil) do
    {:ok, repo} = Repos.create(name, owner)
    repo
  end

  @doc """
  Creates a repository and pushes `commits` into it.

  Each commit is `%{message: ..., change_id: ..., files: %{path => content}}`,
  applied in order on the default branch. An optional `author_date` overrides
  the fixed test date. An `owner` is the user the repository is created for.
  """
  def seed_repo!(name, commits, owner \\ nil) do
    repo = create_repo!(name, owner)
    work = Path.join(System.tmp_dir!(), "pinha-work-" <> random())
    git!(File.cwd!(), ["clone", "--quiet", repo.dir, work])

    Enum.each(commits, fn commit ->
      Enum.each(Map.get(commit, :files, %{}), fn {path, content} ->
        full = Path.join(work, path)
        File.mkdir_p!(Path.dirname(full))
        File.write!(full, content)
      end)

      git!(work, ["add", "-A"])

      date_args =
        case Map.fetch(commit, :author_date) do
          {:ok, author_date} -> ["--date", author_date]
          :error -> []
        end

      git!(work, ["commit", "--quiet", "--message", message(commit)] ++ date_args)
    end)

    git!(work, ["push", "--quiet", "origin", "HEAD:refs/heads/main"])
    File.rm_rf(work)
    {:ok, repo} = Repos.fetch(name)
    repo
  end

  @doc "Runs git in `dir`, raising with its output when it fails."
  def git!(dir, args) do
    env = [
      {"GIT_AUTHOR_NAME", "Tester"},
      {"GIT_AUTHOR_EMAIL", "tester@example.com"},
      {"GIT_COMMITTER_NAME", "Tester"},
      {"GIT_COMMITTER_EMAIL", "tester@example.com"},
      {"GIT_CONFIG_NOSYSTEM", "1"},
      {"GIT_CONFIG_GLOBAL", "/dev/null"},
      {"GIT_AUTHOR_DATE", "2026-01-02T03:04:05+00:00"},
      {"GIT_COMMITTER_DATE", "2026-01-02T03:04:05+00:00"}
    ]

    args = ["-c", "init.defaultBranch=main", "-c", "protocol.file.allow=always" | args]

    case System.cmd("git", args, cd: dir, env: env, stderr_to_stdout: true) do
      {out, 0} -> out
      {out, code} -> raise "git #{Enum.join(args, " ")} failed (#{code}):\n#{out}"
    end
  end

  @doc "The base URL the test endpoint listens on."
  def base_url do
    port = Application.get_env(:pinha, PinhaWeb.Endpoint)[:http][:port]
    "http://127.0.0.1:#{port}"
  end

  @doc "Waits for the supervised background tasks that are already running."
  def await_background_tasks(timeout \\ 5_000) do
    Pinha.TaskSupervisor
    |> Task.Supervisor.children()
    |> Enum.map(&Process.monitor/1)
    |> Enum.each(fn ref ->
      receive do
        {:DOWN, ^ref, :process, _pid, _reason} -> :ok
      after
        timeout -> :ok
      end
    end)
  end

  @doc "A fresh temporary directory, removed when the test ends."
  def tmp_dir! do
    dir = Path.join(System.tmp_dir!(), "pinha-tmp-" <> random())
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    dir
  end

  defp message(commit) do
    case Map.get(commit, :change_id) do
      nil -> commit.message
      change_id -> commit.message <> "\n\nchange-id: " <> change_id
    end
  end

  defp random, do: Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
end
