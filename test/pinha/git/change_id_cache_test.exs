defmodule Pinha.Git.ChangeIdCacheTest do
  use ExUnit.Case, async: false

  alias Pinha.Git.ChangeIdCache

  setup do
    [dir: "/change-id-cache-test/#{System.unique_integer([:positive])}.git"]
  end

  test "lookup/2 splits known ids from unread ones, keeping nil results", %{dir: dir} do
    ChangeIdCache.put(dir, %{"a" => "kmpsxwvrlouvzysnkulnnnttrrytwstn", "b" => nil})

    assert ChangeIdCache.lookup(dir, ["a", "b", "c"]) ==
             {%{"a" => "kmpsxwvrlouvzysnkulnnnttrrytwstn", "b" => nil}, ["c"]}

    assert ChangeIdCache.lookup(dir <> "-other", ["a"]) == {%{}, ["a"]}
  end

  test "a write past the entry limit empties the table first", %{dir: dir} do
    previous = Application.get_env(:pinha, :change_id_cache_max_entries)
    Application.put_env(:pinha, :change_id_cache_max_entries, ChangeIdCache.size() + 1)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:pinha, :change_id_cache_max_entries, previous),
        else: Application.delete_env(:pinha, :change_id_cache_max_entries)
    end)

    ChangeIdCache.put(dir, %{"a" => nil})
    ChangeIdCache.put(dir, %{"b" => nil})

    assert {_found, unread} = ChangeIdCache.lookup(dir, ["a"])
    assert unread == ["a"]
  end
end
