defmodule PinhaWeb.Plugs.GitAwareParsers do
  @moduledoc """
  Runs `Plug.Parsers` for everything except the git RPC endpoints, whose
  bodies belong to `git upload-pack` and `git receive-pack` unread, and the
  provider webhooks, whose exact bytes are what a signature is checked over.
  """

  @behaviour Plug

  @impl true
  def init(opts), do: Plug.Parsers.init(opts)

  @impl true
  def call(conn, opts) do
    if git_rpc?(conn) or webhook?(conn), do: conn, else: Plug.Parsers.call(conn, opts)
  end

  defp webhook?(%Plug.Conn{method: "POST", path_info: ["integrations", _provider, "webhook"]}),
    do: true

  defp webhook?(%Plug.Conn{}), do: false

  # The service is the last segment of a smart HTTP URL, under whatever scope
  # the repository routes are mounted. Matching the whole path pinned this to a
  # prefix, and the prefix has already moved once.
  defp git_rpc?(%Plug.Conn{method: "POST", path_info: path_info}),
    do: List.last(path_info) in ["git-upload-pack", "git-receive-pack"]

  defp git_rpc?(%Plug.Conn{}), do: false
end
