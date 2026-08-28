defmodule PinhaWeb.MetricsController do
  @moduledoc "Prometheus text exposition on the same port, with no auth."

  use PinhaWeb, :controller

  alias Pinha.Metrics

  def index(conn, _params) do
    conn
    |> put_resp_header("content-type", "text/plain; version=0.0.4; charset=utf-8")
    |> send_resp(200, Metrics.render())
  end
end
