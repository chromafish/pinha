defmodule Pinha.Config do
  @moduledoc """
  Operator configuration: the repo root, the public base URL, and the
  background process intervals.
  """

  @doc "Directory holding every `<name>.git` bare repository."
  def repo_root, do: Application.fetch_env!(:pinha, :repo_root)

  @doc "Public base URL used to render clone commands."
  def base_url, do: Application.fetch_env!(:pinha, :base_url)

  def git_bin, do: Application.get_env(:pinha, :git_bin, "git")

  def disk_usage_interval_ms,
    do: Application.get_env(:pinha, :disk_usage_interval_ms, 60_000)

  def maintenance_interval_ms,
    do: Application.get_env(:pinha, :maintenance_interval_ms, 6 * 60 * 60 * 1000)

  def log_max_refs, do: Application.get_env(:pinha, :log_max_refs, 20)

  def widelog?, do: Application.get_env(:pinha, :widelog, true)

  @doc "Whether sign-up stays open once the server has a user."
  def signup_open?, do: Application.get_env(:pinha, :signup_open, false)
end
