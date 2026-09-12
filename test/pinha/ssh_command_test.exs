defmodule Pinha.Ssh.CommandTest do
  use ExUnit.Case, async: true

  alias Pinha.Ssh.Command

  describe "parse/1" do
    test "accepts the two verbs git sends" do
      assert Command.parse("git-upload-pack 'demo.git'") == {:ok, "upload-pack", "demo"}
      assert Command.parse("git-receive-pack 'demo.git'") == {:ok, "receive-pack", "demo"}
    end

    test "reaches the same repository however the remote was written" do
      for path <- ["demo.git", "/demo.git", "~/demo.git", "demo", "/r/demo.git", "r/demo"] do
        assert Command.parse("git-upload-pack '#{path}'") == {:ok, "upload-pack", "demo"}
      end
    end

    test "reads the path whether it is quoted, double quoted, or bare" do
      assert Command.parse(~s(git-upload-pack "demo.git")) == {:ok, "upload-pack", "demo"}
      assert Command.parse("git-upload-pack demo.git") == {:ok, "upload-pack", "demo"}
    end

    test "refuses every other verb" do
      for command <- [
            "git-upload-archive 'demo.git'",
            "git upload-pack 'demo.git'",
            "sh",
            "cat /etc/passwd",
            "git-upload-pack 'a.git' 'b.git'",
            "git-upload-pack"
          ] do
        assert Command.parse(command) == {:error, :unsupported}
      end
    end

    test "refuses a path that leaves the repo root" do
      for path <- [
            "/../../etc/passwd",
            "../demo.git",
            "group/demo.git",
            "/srv/other/demo.git",
            ".hidden.git"
          ] do
        assert Command.parse("git-upload-pack '#{path}'") == {:error, :invalid_name}
      end
    end

    test "refuses a command that never closes its quote" do
      assert Command.parse("git-upload-pack 'demo.git") == {:error, :unsupported}
    end

    test "a quoted separator stays part of one word" do
      assert Command.words("git-upload-pack 'one two'") == ["git-upload-pack", "one two"]
      assert Command.words("a   b\tc") == ["a", "b", "c"]
      assert Command.words("a\\ b") == ["a b"]
    end
  end
end
