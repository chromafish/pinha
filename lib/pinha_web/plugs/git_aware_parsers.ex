defmodule PinhaWeb.Plugs.GitAwareParsers do
  @moduledoc """
  Runs `Plug.Parsers` for everything except the git RPC endpoints, whose
  bodies belong to `git upload-pack` and `git receive-pack` unread.
  """

  @behaviour Plug

  @impl true
  def init(opts), do: Plug.Parsers.init(opts)

  @impl true
  def call(conn, opts) do
    if git_rpc?(conn.path_info), do: conn, else: Plug.Parsers.call(conn, opts)
  end

  defp git_rpc?(path_info) do
    match?([_repo, service] when service in ["git-upload-pack", "git-receive-pack"], path_info)
  end
end
