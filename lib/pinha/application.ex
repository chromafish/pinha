defmodule Pinha.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    File.mkdir_p!(Pinha.Config.repo_root())
    setup_telemetry()

    children =
      [
        Pinha.Repo,
        Pinha.Accounts.Registration,
        {Task.Supervisor, name: Pinha.TaskSupervisor},
        Pinha.Repos.Creator,
        Pinha.Ssh,
        Pinha.Maintenance,
        {Phoenix.PubSub, name: Pinha.PubSub},
        PinhaWeb.Endpoint
      ]

    opts = [strategy: :one_for_one, name: Pinha.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Spans for the HTTP surface come from telemetry events the adapters already
  # emit; the git transports carry their own, since neither is Phoenix.
  defp setup_telemetry do
    OpentelemetryBandit.setup()
    OpentelemetryPhoenix.setup(adapter: :bandit)
    OpentelemetryEcto.setup([:pinha, :repo])
  end

  @impl true
  def config_change(changed, _new, removed) do
    PinhaWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
