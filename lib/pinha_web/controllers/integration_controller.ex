defmodule PinhaWeb.IntegrationController do
  @moduledoc """
  Where a provider comes back to: the authorization callback a browser
  follows, and the webhook a provider posts to.

  The callback belongs to the signed-in user; `Pinha.Providers.Authorizations`
  refuses one that is unknown, expired, or started by anyone else. The
  webhook is unauthenticated by design and verified against the webhook
  secret over the exact bytes of the request.
  """

  use PinhaWeb, :controller

  alias Pinha.Audit
  alias Pinha.Providers
  alias Pinha.Providers.Authorizations
  alias Pinha.Providers.Webhooks

  @max_body 1_000_000

  def callback(conn, %{"provider" => name} = params) do
    case Providers.fetch(name) do
      {:ok, provider} -> finish(conn, provider, params)
      :error -> PinhaWeb.Failure.send(conn, 404, "no such provider")
    end
  end

  defp finish(conn, provider, params) do
    case Authorizations.finish(provider, conn.assigns.current_user, params) do
      {:ok, result} ->
        conn
        |> audit(result)
        |> put_flash(:info, result.message)
        |> redirect(to: result.to)

      {:error, result} ->
        conn
        |> put_flash(:error, result.message)
        |> redirect(to: result.to)

      {:declined, return_to} ->
        conn
        |> put_flash(:error, "#{provider.label()} authorization was declined.")
        |> redirect(to: return_to)

      {:refused, reason} ->
        PinhaWeb.Failure.send(conn, 400, refusal(reason))
    end
  end

  defp refusal(:expired), do: "that authorization has expired; start it again"
  defp refusal(_reason), do: "that authorization is not one you started"

  defp audit(conn, %{audit: {event, fields}}),
    do: Audit.put(conn, event, conn.assigns.current_user, fields)

  defp audit(conn, _result), do: conn

  def webhook(conn, %{"provider" => name}) do
    with {:ok, provider} <- fetch_provider(name),
         {:ok, body, conn} <- read_body(conn, length: @max_body) do
      case Webhooks.receive_delivery(provider, headers(conn), body) do
        :ok -> send_resp(conn, 202, "")
        :duplicate -> send_resp(conn, 200, "")
        {:error, :invalid_signature} -> send_resp(conn, 401, "")
        {:error, :malformed} -> send_resp(conn, 400, "")
      end
    else
      :error -> send_resp(conn, 404, "")
      {:more, _partial, conn} -> send_resp(conn, 413, "")
      {:error, _reason} -> send_resp(conn, 400, "")
    end
  end

  defp fetch_provider(name), do: Providers.fetch(name)

  defp headers(conn) do
    Map.new(conn.req_headers, fn {name, value} -> {String.downcase(name), value} end)
  end
end
