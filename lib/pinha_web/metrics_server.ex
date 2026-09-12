defmodule PinhaWeb.MetricsServer do
  @moduledoc """
  Serves `GET /metrics` on a listener of its own, and nothing else.

  Bound to loopback by default, with no authentication: what can reach the
  address is the access control.
  """

  use Plug.Router

  alias Pinha.Config
  alias Pinha.Metrics

  require Logger

  plug :match
  plug :dispatch

  get "/metrics" do
    conn
    |> put_resp_header("content-type", "text/plain; version=0.0.4; charset=utf-8")
    |> send_resp(200, Metrics.render())
  end

  match _ do
    send_resp(conn, 404, "not found\n")
  end

  @doc "The listener's child spec, or an empty list when metrics are switched off."
  @spec children() :: [Supervisor.child_spec() | {module(), term()}]
  def children do
    if Config.metrics_enabled?() do
      options = [
        plug: __MODULE__,
        scheme: :http,
        port: Config.metrics_port(),
        ip: Config.metrics_listen_ip(),
        startup_log: false
      ]

      [Supervisor.child_spec({Bandit, options}, id: __MODULE__)]
    else
      []
    end
  end
end
