defmodule Pinha.Ssh.KeyCb do
  @moduledoc """
  Public-key authentication for the SSH listener.

  The daemon offers no password and no keyboard-interactive method, so this is
  the only way in. A key is looked up by its SHA-256 fingerprint, which is one
  indexed read, and the user it names is bound to the connection for its
  lifetime: the channel that later runs git already knows who is pushing.

  The SSH username is the same for everyone and says nothing; a client that
  sends another one is refused before the key is even considered.
  """

  @behaviour :ssh_server_key_api

  alias Pinha.Accounts
  alias Pinha.Accounts.SshKey
  alias Pinha.Config
  alias Pinha.Ssh

  require Logger

  @impl true
  def host_key(algorithm, options), do: :ssh_file.host_key(algorithm, options)

  @impl true
  def is_auth_key(key, user, _options) do
    with true <- to_string(user) == Config.ssh_user(),
         {:ok, fingerprint} <- SshKey.fingerprint(key),
         {:ok, account} <- Accounts.fetch_user_by_ssh_fingerprint(fingerprint) do
      Ssh.bind(self(), account.uid)
      true
    else
      _ ->
        refuse(key, user)
        false
    end
  end

  defp refuse(key, user) do
    fingerprint =
      case SshKey.fingerprint(key) do
        {:ok, fingerprint} -> SshKey.format_fingerprint(fingerprint)
        :error -> "unreadable"
      end

    Logger.warning("ssh auth refused: user=#{inspect(to_string(user))} key=#{fingerprint}")
  end
end
