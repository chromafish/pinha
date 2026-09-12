defmodule Pinha.ReposTest do
  use Pinha.RepoCase, async: false

  alias Pinha.Git

  describe "normalize_name/1" do
    test "strips the .git suffix" do
      assert Repos.normalize_name("foo.git") == {:ok, "foo"}
      assert Repos.normalize_name("foo") == {:ok, "foo"}
    end

    test "rejects anything that is not a single safe path segment" do
      names = [
        "",
        "..",
        ".hidden",
        "group/foo",
        "foo/../bar",
        "foo bar",
        "-foo",
        String.duplicate("x", 65)
      ]

      for name <- names do
        assert Repos.normalize_name(name) == {:error, :invalid_name}, "accepted #{inspect(name)}"
      end
    end
  end

  describe "create/1" do
    test "initializes a bare repo with http.receivepack enabled", %{root: root} do
      assert {:ok, repo} = Repos.create("demo")
      assert repo.dir == Path.join(root, "demo.git")
      assert Repos.bare_repo?(repo.dir)
      assert {:ok, "true\n"} = Git.run(repo.dir, ["config", "http.receivepack"])
      assert {:ok, "git\n"} = Git.run(repo.dir, ["config", "pinha.kind"])
      assert repo.kind == :git
    end

    test "accepts a name given with the .git suffix" do
      assert {:ok, repo} = Repos.create("demo.git")
      assert repo.name == "demo"
    end

    test "leaves no temporary directory behind", %{root: root} do
      {:ok, _} = Repos.create("demo")
      assert File.ls!(root) == ["demo.git"]
    end

    test "the loser of a duplicate create gets :exists" do
      {:ok, _} = Repos.create("demo")
      assert Repos.create("demo") == {:error, :exists}
    end

    test "concurrent creates of the same name produce exactly one winner" do
      results =
        1..8
        |> Task.async_stream(fn _ -> Repos.create("race") end, max_concurrency: 8)
        |> Enum.map(fn {:ok, result} -> result end)

      assert Enum.count(results, &match?({:ok, _}, &1)) == 1
      assert Enum.count(results, &(&1 == {:error, :exists})) == 7
    end

    test "rejects invalid names" do
      assert Repos.create("../evil") == {:error, :invalid_name}
    end
  end

  describe "list/0" do
    test "returns valid bare repos only, sorted", %{root: root} do
      {:ok, _} = Repos.create("beta")
      {:ok, _} = Repos.create("alpha")
      File.mkdir_p!(Path.join(root, "not-a-repo"))
      File.mkdir_p!(Path.join(root, "broken.git"))

      assert Enum.map(Repos.list(), & &1.name) == ["alpha", "beta"]
    end

    test "reads the description file, ignoring git's placeholder" do
      {:ok, repo} = Repos.create("demo")
      assert Repos.description(repo.dir) == nil

      File.write!(Path.join(repo.dir, "description"), "the demo repo\n")
      assert [%{description: "the demo repo"}] = Repos.list()
    end

    test "reads the durable repository kind and treats an absent marker as Git" do
      {:ok, marked} = Repos.create("marked")
      assert {:ok, _} = Git.run(marked.dir, ["config", "pinha.kind", "jj"])

      manual = Repos.dir("manual")
      File.mkdir_p!(manual)
      assert {:ok, _} = Git.run(manual, ["init", "--bare", "--quiet", "."])

      assert [%{name: "manual", kind: :git}, %{name: "marked", kind: :jj}] = Repos.list()
    end
  end

  describe "fetch/1" do
    test "resolves with or without the .git suffix" do
      {:ok, _} = Repos.create("demo")
      assert {:ok, %{name: "demo"}} = Repos.fetch("demo")
      assert {:ok, %{name: "demo"}} = Repos.fetch("demo.git")
    end

    test "reports missing and invalid names apart" do
      assert Repos.fetch("missing") == {:error, :not_found}
      assert Repos.fetch("../evil") == {:error, :invalid_name}
    end

    test "reports a directory that is not a bare repository", %{root: root} do
      File.mkdir_p!(Path.join(root, "broken.git"))
      assert Repos.fetch("broken") == {:error, :invalid_repo}
    end
  end

  describe "delete/1" do
    test "removes the repo from the listing immediately" do
      {:ok, _} = Repos.create("demo")
      assert :ok = Repos.delete("demo")
      assert Repos.list() == []
      assert Repos.fetch("demo") == {:error, :not_found}
    end

    test "removes the directory from disk in the background", %{root: root} do
      {:ok, _} = Repos.create("demo")
      :ok = Repos.delete("demo")
      await_background_tasks()

      assert File.ls!(root) == []
    end

    test "reports missing repos" do
      assert Repos.delete("missing") == {:error, :not_found}
    end
  end
end
