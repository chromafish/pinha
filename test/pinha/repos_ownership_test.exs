defmodule Pinha.ReposOwnershipTest do
  @moduledoc "Who owns a repository, where that is written, and who may write."

  use Pinha.DataCase, async: false
  use Pinha.RepoCase, async: false

  alias Pinha.Git
  alias Pinha.Repos

  describe "create/2" do
    test "records the creator in the repo's own config" do
      user = user_fixture()
      {:ok, repo} = Repos.create("demo", user)

      assert repo.owner_uid == user.uid
      assert {:ok, out} = Git.run(repo.dir, ["config", "--get", "pinha.owner"])
      assert String.trim(out) == user.uid

      assert {:ok, fetched} = Repos.fetch("demo")
      assert fetched.owner_uid == user.uid
      assert {:ok, owner} = Repos.owner(fetched)
      assert owner.id == user.id
    end

    test "a repo made by hand has no owner" do
      {:ok, repo} = Repos.create("demo")

      assert repo.owner_uid == nil
      assert Repos.owner(repo) == :error
    end

    test "reads the owner out of the config file git wrote" do
      user = user_fixture()
      {:ok, repo} = Repos.create("demo", user)

      assert Repos.owner_uid(repo.dir) == user.uid
      assert File.read!(Path.join(repo.dir, "config")) =~ "[pinha]"
    end
  end

  describe "writable_by?/2" do
    test "the owner writes, and so does an admin" do
      owner = user_fixture()
      admin = user_fixture(%{admin: true})
      stranger = user_fixture()
      {:ok, repo} = Repos.create("demo", owner)

      assert Repos.writable_by?(repo, owner)
      assert Repos.writable_by?(repo, admin)
      refute Repos.writable_by?(repo, stranger)
      refute Repos.writable_by?(repo, nil)
    end

    test "an unowned repo is left to admins" do
      {:ok, repo} = Repos.create("demo")

      refute Repos.writable_by?(repo, user_fixture())
      assert Repos.writable_by?(repo, user_fixture(%{admin: true}))
    end

    test "a repo whose owner was deleted falls back to admins" do
      owner = user_fixture()
      {:ok, repo} = Repos.create("demo", owner)
      Pinha.Repo.delete!(owner)

      {:ok, repo} = Repos.fetch(repo.name)

      assert repo.owner_uid == owner.uid
      assert Repos.owner(repo) == :error
      refute Repos.writable_by?(repo, user_fixture())
      assert Repos.writable_by?(repo, user_fixture(%{admin: true}))
    end
  end

  describe "set_owner/2" do
    test "hands the repo over by email" do
      first = user_fixture()
      second = user_fixture()
      {:ok, _} = Repos.create("demo", first)

      assert {:ok, repo} = Repos.set_owner("demo", second.email)
      assert repo.owner_uid == second.uid

      {:ok, reread} = Repos.fetch("demo")
      assert reread.owner_uid == second.uid
      assert Repos.writable_by?(reread, second)
      refute Repos.writable_by?(reread, first)
    end

    test "reports an email nobody registered, and a repo that is not there" do
      {:ok, _} = Repos.create("demo")

      assert Repos.set_owner("demo", "nobody@example.com") == {:error, :no_such_user}
      assert Repos.set_owner("missing", "nobody@example.com") == {:error, :not_found}
    end

    test "survives the owner changing their email" do
      user = user_fixture()
      {:ok, repo} = Repos.create("demo", user)

      user
      |> Ecto.Changeset.change(email: "renamed#{System.unique_integer([:positive])}@example.com")
      |> Pinha.Repo.update!()

      {:ok, repo} = Repos.fetch(repo.name)
      {:ok, owner} = Repos.owner(repo)

      assert owner.id == user.id
      assert Repos.writable_by?(repo, owner)
    end
  end
end
