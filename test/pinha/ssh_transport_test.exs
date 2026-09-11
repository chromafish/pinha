defmodule Pinha.SshTransportTest do
  @moduledoc """
  The SSH transport driven by a real `git` over a real `ssh`.

  Everything here goes through the listener the application started, so a test
  that passes is a clone or a push that a person could have run.
  """

  use PinhaWeb.ConnCase, async: false

  alias Pinha.Accounts
  alias Pinha.Metrics
  alias Pinha.Ssh

  @change_id "kmpsxwvrlouvzysnkulnnnttrrytwstn"

  setup %{user: user} do
    keys = tmp_dir!()
    key = Path.join(keys, "id_ed25519")
    {_out, 0} = System.cmd("ssh-keygen", ["-q", "-t", "ed25519", "-N", "", "-f", key])
    {:ok, _} = Accounts.add_ssh_key(user, File.read!(key <> ".pub"), "test key")

    [key: key, url: ssh_url("demo")]
  end

  describe "clone and push" do
    test "a round trip over ssh", %{key: key, url: url, user: user} do
      create_repo!("demo", user)
      work = tmp_dir!()
      clone = Path.join(work, "one")

      ssh_git!(key, work, ["clone", "--quiet", url, clone])

      File.write!(Path.join(clone, "README.md"), "hello\n")
      ssh_git!(key, clone, ["add", "-A"])
      ssh_git!(key, clone, ["commit", "--quiet", "-m", "first\n\nchange-id: #{@change_id}"])
      ssh_git!(key, clone, ["push", "--quiet", "origin", "main"])

      second = Path.join(work, "two")
      ssh_git!(key, work, ["clone", "--quiet", url, second])

      assert File.read!(Path.join(second, "README.md")) == "hello\n"
      assert ssh_git!(key, second, ["log", "--format=%B", "-1"]) =~ "change-id: #{@change_id}"
    end

    test "the scp-style remote reaches the same repository", %{key: key, user: user} do
      seed_repo!("demo", [%{message: "first", files: %{"a.txt" => "a\n"}}])
      {:ok, _} = Pinha.Repos.set_owner("demo", user.email)

      work = tmp_dir!()
      remote = "ssh://git@127.0.0.1:#{Ssh.port()}/demo.git"
      ssh_git!(key, work, ["clone", "--quiet", remote, Path.join(work, "clone")])

      assert File.read!(Path.join([work, "clone", "a.txt"])) == "a\n"
    end

    test "counts the fetch and the push against the ssh transport", %{
      key: key,
      url: url,
      user: user
    } do
      create_repo!("demo", user)
      work = tmp_dir!()
      clone = Path.join(work, "one")

      ssh_git!(key, work, ["clone", "--quiet", url, clone])
      File.write!(Path.join(clone, "a.txt"), "a\n")
      ssh_git!(key, clone, ["add", "-A"])
      ssh_git!(key, clone, ["commit", "--quiet", "-m", "first"])
      ssh_git!(key, clone, ["push", "--quiet", "origin", "main"])

      metrics = IO.iodata_to_binary(Metrics.render())

      assert metrics =~ ~r/git_fetches_total\{repo="demo",transport="ssh"\} [1-9]/
      assert metrics =~ ~r/git_pushes_total\{repo="demo",transport="ssh"\} [1-9]/
    end
  end

  describe "refusals" do
    test "a key nobody registered is refused", %{user: user} do
      create_repo!("demo", user)
      stranger = Path.join(tmp_dir!(), "id_ed25519")
      {_out, 0} = System.cmd("ssh-keygen", ["-q", "-t", "ed25519", "-N", "", "-f", stranger])

      {output, status} =
        ssh_git(stranger, tmp_dir!(), ["clone", "--quiet", ssh_url("demo"), "clone"])

      assert status != 0
      assert output =~ "Permission denied" or output =~ "publickey"
    end

    test "someone else's repository reads but does not write", %{user: user} do
      seed_repo!("demo", [%{message: "first", files: %{"a.txt" => "a\n"}}])
      {:ok, _} = Pinha.Repos.set_owner("demo", user.email)

      # The test's own user is an admin, who may push anywhere, so the pusher
      # here is an ordinary account with a key of its own.
      ordinary = user_fixture()
      key = Path.join(tmp_dir!(), "id_ed25519")
      {_out, 0} = System.cmd("ssh-keygen", ["-q", "-t", "ed25519", "-N", "", "-f", key])
      {:ok, _} = Accounts.add_ssh_key(ordinary, File.read!(key <> ".pub"), "theirs")

      work = tmp_dir!()
      clone = Path.join(work, "clone")
      ssh_git!(key, work, ["clone", "--quiet", ssh_url("demo"), clone])

      File.write!(Path.join(clone, "b.txt"), "b\n")
      ssh_git!(key, clone, ["add", "-A"])
      ssh_git!(key, clone, ["commit", "--quiet", "-m", "second"])

      {output, status} = ssh_git(key, clone, ["push", "origin", "main"])

      assert status != 0
      assert output =~ "you do not have push access to demo"
    end

    test "a shell session is refused", %{key: key} do
      {output, status} = ssh(key, [])

      assert status != 0
      assert output =~ "git and nothing else"
    end

    test "any other command is refused", %{key: key} do
      {output, status} = ssh(key, ["id"])

      assert status != 0
      assert output =~ "only git-upload-pack and git-receive-pack"
    end

    test "a repository that does not exist is named in the refusal", %{key: key} do
      {output, status} = ssh(key, ["git-upload-pack 'missing.git'"])

      assert status != 0
      assert output =~ "no such repository: missing"
    end

    test "a path outside the repo root is refused as a name", %{key: key} do
      {output, status} = ssh(key, ["git-upload-pack '/../../etc/passwd'"])

      assert status != 0
      assert output =~ "invalid repository name"
    end
  end

  defp ssh_url(name), do: "ssh://git@127.0.0.1:#{Ssh.port()}/#{name}.git"

  defp ssh_command(key) do
    "ssh -i #{key} -o IdentitiesOnly=yes -o StrictHostKeyChecking=no " <>
      "-o UserKnownHostsFile=/dev/null -o BatchMode=yes -o LogLevel=ERROR"
  end

  defp ssh(key, args) do
    System.cmd(
      "ssh",
      [
        "-i",
        key,
        "-o",
        "IdentitiesOnly=yes",
        "-o",
        "StrictHostKeyChecking=no",
        "-o",
        "UserKnownHostsFile=/dev/null",
        "-o",
        "BatchMode=yes",
        "-o",
        "LogLevel=ERROR",
        "-p",
        to_string(Ssh.port()),
        "git@127.0.0.1"
      ] ++ args,
      stderr_to_stdout: true
    )
  end

  defp ssh_git(key, dir, args) do
    env = [
      {"GIT_SSH_COMMAND", ssh_command(key)},
      {"GIT_AUTHOR_NAME", "Tester"},
      {"GIT_AUTHOR_EMAIL", "tester@example.com"},
      {"GIT_COMMITTER_NAME", "Tester"},
      {"GIT_COMMITTER_EMAIL", "tester@example.com"},
      {"GIT_CONFIG_NOSYSTEM", "1"},
      {"GIT_CONFIG_GLOBAL", "/dev/null"}
    ]

    System.cmd("git", args, cd: dir, env: env, stderr_to_stdout: true)
  end

  defp ssh_git!(key, dir, args) do
    case ssh_git(key, dir, args) do
      {out, 0} -> out
      {out, code} -> raise "git #{Enum.join(args, " ")} failed (#{code}):\n#{out}"
    end
  end
end
