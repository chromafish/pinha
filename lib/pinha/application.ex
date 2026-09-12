defmodule Pinha.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    File.mkdir_p!(Pinha.Config.repo_root())

    children =
      [
        Pinha.Repo,
        Pinha.Accounts.Registration,
        Pinha.Metrics,
        {Task.Supervisor, name: Pinha.TaskSupervisor},
        Pinha.Repos.Creator,
        Pinha.Ssh,
        Pinha.DiskUsage,
        Pinha.Maintenance,
        PinhaWeb.Telemetry,
        {Phoenix.PubSub, name: Pinha.PubSub},
        PinhaWeb.Endpoint
      ] ++ PinhaWeb.MetricsServer.children()

    opts = [strategy: :one_for_one, name: Pinha.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @impl true
  def config_change(changed, _new, removed) do
    PinhaWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
