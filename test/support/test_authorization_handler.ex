defmodule Pinha.TestAuthorizationHandler do
  @moduledoc """
  An authorization handler for the suite. It reports what it was given to
  the process registered as `:authorization_probe`, including whether its own
  process is hidden from runtime introspection.
  """

  @behaviour Pinha.Providers.AuthorizationHandler

  alias Pinha.Providers.Secret

  @impl true
  def handle_authorization(%{user: user, token: token, params: params, callback: callback}) do
    Process.put(:probe, "something a crash report must not show")

    send(
      :authorization_probe,
      {:handled,
       %{
         token: Secret.reveal(token),
         user_id: user.id,
         params: params,
         callback: callback,
         dictionary: Process.info(self(), :dictionary)
       }}
    )

    {:ok, %{to: params["return_to"] || "/", message: "handled"}}
  end
end
