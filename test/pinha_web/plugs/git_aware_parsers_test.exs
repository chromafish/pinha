defmodule PinhaWeb.Plugs.GitAwareParsersTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias PinhaWeb.Plugs.GitAwareParsers

  # A form content type is what makes the skip visible: the parser would
  # consume this body happily, so unfetched params mean it never ran.
  @opts GitAwareParsers.init(parsers: [:urlencoded], pass: ["*/*"])
  @body "a=1"

  defp run(method, path) do
    method
    |> conn(path, @body)
    |> put_req_header("content-type", "application/x-www-form-urlencoded")
    |> GitAwareParsers.call(@opts)
  end

  test "leaves an upload-pack body for the transport to read" do
    assert %Plug.Conn.Unfetched{} = run(:post, "/r/demo.git/git-upload-pack").params
  end

  test "leaves a receive-pack body for the transport to read" do
    assert %Plug.Conn.Unfetched{} = run(:post, "/r/demo.git/git-receive-pack").params
  end

  test "parses everything else, including the ref advertisement" do
    assert run(:post, "/settings/tokens").params == %{"a" => "1"}
    assert run(:get, "/r/demo.git/info/refs").params == %{}
  end

  test "parses a write to a repository whose name is a service name" do
    assert run(:delete, "/r/git-receive-pack").params == %{"a" => "1"}
  end
end
