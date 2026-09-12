defmodule Pinha.Ssh.ChannelTest do
  @moduledoc """
  The session callbacks, driven directly.

  A client that disappears mid-clone is hard to stage through a real `ssh`,
  but it reaches the channel as a plain callback, so the callbacks are what
  this exercises.
  """

  use ExUnit.Case, async: false

  alias Pinha.Ssh.Channel
  alias Pinha.Ssh.Channel.State

  import ExUnit.CaptureIO

  setup do
    previous = Application.get_env(:pinha, :widelog)
    Application.put_env(:pinha, :widelog, true)
    on_exit(fn -> Application.put_env(:pinha, :widelog, previous) end)
    :ok
  end

  test "a session cut short is still reported" do
    state = %State{
      started_at: System.monotonic_time(),
      subcommand: "upload-pack",
      repo: %Pinha.Repos.Repo{name: "demo", dir: "/tmp/demo.git"},
      peer: "127.0.0.1:4242",
      req_bytes: 10,
      resp_bytes: 20
    }

    output = capture_io(fn -> Channel.terminate(:shutdown, state) end)

    assert {:ok, line} = Jason.decode(output)
    assert line["transport"] == "ssh"
    assert line["repo"] == "demo"
    assert line["git"] == "upload-pack"
    assert line["status"] == 130
  end

  test "a session that finished is not reported twice" do
    state = %State{
      started_at: System.monotonic_time(),
      subcommand: "upload-pack",
      repo: %Pinha.Repos.Repo{name: "demo", dir: "/tmp/demo.git"},
      finished: true
    }

    assert capture_io(fn -> Channel.terminate(:normal, state) end) == ""
  end

  test "a second exec on one channel is refused, leaving the first alone" do
    running = %State{
      id: 0,
      cm: self(),
      started_at: System.monotonic_time(),
      subcommand: "upload-pack",
      port: :a_port,
      stderr_path: "/tmp/first",
      span: :a_span
    }

    assert {:ok, ^running} =
             Channel.handle_ssh_msg(
               {:ssh_cm, self(), {:exec, 0, false, ~c"git-upload-pack 'other.git'"}},
               running
             )
  end

  test "a connection that never ran anything says nothing" do
    assert capture_io(fn -> Channel.terminate(:normal, %State{}) end) == ""
  end
end
