defmodule Pinha.Repo do
  @moduledoc """
  The user store.

  Repositories and their objects stay on disk; this holds only who may reach
  them: users, their passkeys, web sessions, and the tokens git sends over
  HTTP Basic.
  """

  use Ecto.Repo,
    otp_app: :pinha,
    adapter: Ecto.Adapters.Postgres
end
