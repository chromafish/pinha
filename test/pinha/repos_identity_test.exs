defmodule Pinha.ReposIdentityTest do
  @moduledoc "The repository ID a mirror follows, and the snapshot it copies."

  # Deleting a repository removes its mirror, which is a database row.
  use Pinha.DataCase, async: false
  use Pinha.RepoCase, async: false

  alias Pinha.Repos

  describe "pinha.id" do
    test "is minted at create, in its own shape" do
      {:ok, repo} = Repos.create("demo")

      assert repo.id =~ ~r/\Ar_[a-z2-7]{26}\z/
      assert {:ok, fetched} = Repos.fetch("demo")
      assert fetched.id == repo.id
    end

    test "is never reused by a repository created under the same name" do
      {:ok, one} = Repos.create("demo")
      :ok = Repos.delete("demo")
      {:ok, two} = Repos.create("demo")

      refute one.id == two.id
    end

    test "a repository made by hand has none until something needs it", %{root: root} do
      dir = Path.join(root, "handmade.git")
      git!(File.cwd!(), ["init", "--bare", "--quiet", dir])

      assert {:ok, repo} = Repos.fetch("handmade")
      assert repo.id == nil

      # Listing and browsing read the ID and never write one.
      assert [%{id: nil}] = Repos.list()
      assert Repos.id(dir) == nil

      assert {:ok, minted} = Repos.ensure_id(repo)
      assert minted.id =~ ~r/\Ar_[a-z2-7]{26}\z/
      assert Repos.id(dir) == minted.id

      assert {:ok, again} = Repos.ensure_id(%{minted | id: nil})
      assert again.id == minted.id
    end
  end

  describe "snapshot/1" do
    test "lists branches and tags with the object each names" do
      repo = seed_repo!("demo", [%{message: "first", files: %{"a.txt" => "a\n"}}])
      git!(repo.dir, ["tag", "v1", "main"])
      git!(repo.dir, ["branch", "topic", "main"])
      # Anything outside the two namespaces is not part of a snapshot.
      git!(repo.dir, ["update-ref", "refs/jj/keep", "main"])

      assert {:ok, snapshot} = Repos.snapshot(repo)

      assert Map.keys(snapshot.refs) |> Enum.sort() ==
               ["refs/heads/main", "refs/heads/topic", "refs/tags/v1"]

      assert snapshot.conflicted == []
      assert DateTime.compare(snapshot.taken_at, DateTime.utc_now()) in [:lt, :eq]
    end

    test "is taken before the references are read, so a write it missed reads as later" do
      repo = seed_repo!("demo", [%{message: "first", files: %{"a.txt" => "a\n"}}])
      {:ok, snapshot} = Repos.snapshot(repo)

      assert DateTime.compare(snapshot.taken_at, DateTime.utc_now()) in [:lt, :eq]
      assert map_size(snapshot.refs) == 1
    end
  end
end
