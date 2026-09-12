ExUnit.start()

# Tests that touch the database check a connection out themselves; the rest
# of the suite drives git over HTTP and never reaches the repo.
Ecto.Adapters.SQL.Sandbox.mode(Pinha.Repo, :manual)

# The suite's GitHub App key, generated per run so no private key is kept in
# the repository. Everything else about the app is in config/test.exs.
private_key =
  {:rsa, 2048, 65_537}
  |> :public_key.generate_key()
  |> then(&:public_key.pem_entry_encode(:RSAPrivateKey, &1))
  |> List.wrap()
  |> :public_key.pem_encode()

Application.put_env(
  :pinha,
  Pinha.Providers.GitHub,
  Keyword.put(
    Application.get_env(:pinha, Pinha.Providers.GitHub),
    :private_key,
    private_key
  )
)
