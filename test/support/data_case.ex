defmodule Pinha.DataCase do
  @moduledoc "For tests that touch the database and nothing else."

  use ExUnit.CaseTemplate

  using do
    quote do
      import Pinha.AccountsFixtures

      alias Pinha.Accounts
    end
  end

  setup tags do
    owner = Ecto.Adapters.SQL.Sandbox.start_owner!(Pinha.Repo, shared: not tags[:async])
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(owner) end)
    :ok
  end
end
