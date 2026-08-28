defmodule PinhaWeb.ConnCase do
  @moduledoc """
  This module defines the test case to be used by
  tests that require setting up a connection.

  Such tests rely on `Phoenix.ConnTest` and also
  import other functionality to make it easier
  to build common data structures and query the data layer.

  Tests share one repo root through the application environment, so they run
  serially.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      # The default endpoint for testing
      @endpoint PinhaWeb.Endpoint

      use PinhaWeb, :verified_routes

      # Import conveniences for testing with connections
      import Plug.Conn
      import Phoenix.ConnTest
      import PinhaWeb.ConnCase
      import Pinha.RepoCase
      alias Pinha.Repos
    end
  end

  setup _tags do
    {:ok, conn: Phoenix.ConnTest.build_conn(), root: Pinha.RepoCase.setup_root!()}
  end
end
