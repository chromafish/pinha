defmodule Pinha.Config do
  @moduledoc """
  Operator configuration: the repo root, the public base URL, the SSH and
  metrics listeners, and the background process intervals.
  """

  @doc "Directory holding every `<name>.git` bare repository."
  def repo_root, do: Application.fetch_env!(:pinha, :repo_root)

  @doc "Public base URL used to render clone commands."
  def base_url, do: Application.fetch_env!(:pinha, :base_url)

  def git_bin, do: Application.get_env(:pinha, :git_bin, "git")

  @doc "Whether the metrics listener runs at all."
  def metrics_enabled?, do: Application.get_env(:pinha, :metrics_enabled, true)

  @doc "Port the metrics listener binds."
  def metrics_port, do: Application.get_env(:pinha, :metrics_port, 9568)

  @doc "Address the metrics listener binds. Loopback unless an operator says otherwise."
  def metrics_listen_ip, do: Application.get_env(:pinha, :metrics_listen_ip, {127, 0, 0, 1})

  @doc "Whether the SSH listener runs at all."
  def ssh_enabled?, do: Application.get_env(:pinha, :ssh_enabled, true)

  @doc "Port the SSH listener binds. Zero asks the OS for one, which the suite does."
  def ssh_port, do: Application.get_env(:pinha, :ssh_port, 2222)

  @doc "Address the SSH listener binds, or nil for every interface."
  def ssh_listen_ip, do: Application.get_env(:pinha, :ssh_listen_ip)

  @doc """
  The single SSH username every client connects as.

  It is not an OS account: identity comes from the key, and this is only what
  `git@host` has to say to get that far.
  """
  def ssh_user, do: Application.get_env(:pinha, :ssh_user, "git")

  @doc "Host rendered in SSH clone URLs, defaulting to the base URL's host."
  def ssh_host do
    Application.get_env(:pinha, :ssh_host) || URI.parse(base_url()).host || "localhost"
  end

  @doc """
  Directory holding the host key.

  It sits under the repo root by default, where the repo listing skips it for
  not ending in `.git`, so a backup of the root carries the host key and
  clients keep their `known_hosts` entry across a restore.
  """
  def ssh_host_key_dir do
    Application.get_env(:pinha, :ssh_host_key_dir) || Path.join(repo_root(), ".pinha/ssh")
  end

  def disk_usage_interval_ms,
    do: Application.get_env(:pinha, :disk_usage_interval_ms, 60_000)

  def maintenance_interval_ms,
    do: Application.get_env(:pinha, :maintenance_interval_ms, 6 * 60 * 60 * 1000)

  def log_max_refs, do: Application.get_env(:pinha, :log_max_refs, 20)

  def widelog?, do: Application.get_env(:pinha, :widelog, true)
end
