ExUnit.start()

# Tests that touch the database check a connection out themselves; the rest
# of the suite drives git over HTTP and never reaches the repo.
Ecto.Adapters.SQL.Sandbox.mode(Pinha.Repo, :manual)
