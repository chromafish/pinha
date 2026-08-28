defmodule PinhaWeb.Failure do
  @moduledoc "Renders an error as HTML or JSON depending on the negotiated format."

  import Plug.Conn
  import Phoenix.Controller

  @doc "Sends `message` with `status` in the request's format."
  @spec send(Plug.Conn.t(), pos_integer(), String.t()) :: Plug.Conn.t()
  def send(conn, status, message) do
    case get_format(conn) do
      "json" ->
        conn |> put_status(status) |> json(%{error: message})

      _ ->
        conn
        |> put_status(status)
        |> put_view(html: PinhaWeb.PageHTML)
        |> render(:error, status: status, message: message)
    end
  end
end
