defmodule Pinha.SshHostKeyTest do
  use ExUnit.Case, async: false

  alias Pinha.Accounts.SshKey
  alias Pinha.Ssh

  setup do
    dir = Path.join(System.tmp_dir!(), "pinha-hostkey-#{System.unique_integer([:positive])}")
    previous = Application.get_env(:pinha, :ssh_host_key_dir)
    Application.put_env(:pinha, :ssh_host_key_dir, dir)

    on_exit(fn ->
      Application.put_env(:pinha, :ssh_host_key_dir, previous)
      File.rm_rf(dir)
    end)

    [dir: dir]
  end

  test "generates a key the daemon can read and an operator can publish", %{dir: dir} do
    assert Ssh.ensure_host_key!() == dir

    private = Path.join(dir, "ssh_host_ed25519_key")
    assert File.exists?(private)
    assert File.stat!(private).mode |> rem(0o1000) == 0o600

    # The same reader the daemon uses.
    assert {:ok, _key} = :ssh_file.host_key(:"ssh-ed25519", system_dir: to_charlist(dir))

    # Read back from PKCS#8, which does not carry the public half.
    fingerprint = Ssh.host_key_fingerprint(dir)
    assert fingerprint =~ ~r/\ASHA256:[A-Za-z0-9+\/]+\z/

    {:ok, published} = SshKey.parse(File.read!(private <> ".pub"))
    assert SshKey.format_fingerprint(published.fingerprint) == fingerprint
  end

  test "keeps the key it already has", %{dir: dir} do
    Ssh.ensure_host_key!()
    first = File.read!(Path.join(dir, "ssh_host_ed25519_key"))

    Ssh.ensure_host_key!()

    assert File.read!(Path.join(dir, "ssh_host_ed25519_key")) == first
  end
end
