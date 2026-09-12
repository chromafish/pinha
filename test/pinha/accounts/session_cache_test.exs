defmodule Pinha.Accounts.SessionCacheTest do
  use Pinha.DataCase, async: false

  alias Pinha.Accounts.Session
  alias Pinha.Accounts.SessionCache
  alias Pinha.Repo

  @cache_event [:pinha, :accounts, :session_cache]
  @query_event [:pinha, :repo, :query]

  setup do
    handler_id = {__MODULE__, self(), make_ref()}
    :ok = :telemetry.attach(handler_id, @cache_event, &__MODULE__.handle_cache_event/4, self())
    on_exit(fn -> :telemetry.detach(handler_id) end)
    :ok
  end

  test "a cold lookup fills the cache and the next lookup stays off Postgres" do
    user = user_fixture()
    token = Accounts.create_session(user)
    token_hash = hash(token)
    :ok = SessionCache.evict(token_hash)

    assert {:ok, loaded} = Accounts.fetch_user_by_session_token(token)
    assert loaded.id == user.id
    assert_receive {:session_cache, %{count: 1}, %{result: :miss}}

    query_handler_id = {__MODULE__, :query, self(), make_ref()}

    :ok =
      :telemetry.attach(
        query_handler_id,
        @query_event,
        &__MODULE__.handle_query_event/4,
        self()
      )

    on_exit(fn -> :telemetry.detach(query_handler_id) end)

    assert {:ok, cached} = Accounts.fetch_user_by_session_token(token)
    assert cached.id == user.id
    assert_receive {:session_cache, %{count: 1}, %{result: :hit}}
    refute_receive :repo_query
  end

  test "an expired cache entry revalidates against Postgres without sleeping" do
    user = user_fixture()
    token = Accounts.create_session(user)
    token_hash = hash(token)
    :ok = SessionCache.put(token_hash, user, ttl_ms: 0)

    assert {:ok, loaded} = Accounts.fetch_user_by_session_token(token)
    assert loaded.id == user.id
    assert_receive {:session_cache, %{count: 1}, %{result: :miss}}

    assert {:ok, _cached} = Accounts.fetch_user_by_session_token(token)
    assert_receive {:session_cache, %{count: 1}, %{result: :hit}}
  end

  test "deleting a session evicts its warm entry immediately" do
    user = user_fixture()
    token = Accounts.create_session(user)

    assert {:ok, _user} = Accounts.fetch_user_by_session_token(token)
    assert_receive {:session_cache, _measurements, %{result: :hit}}

    assert :ok = Accounts.delete_session(token)
    assert :error = Accounts.fetch_user_by_session_token(token)
    assert_receive {:session_cache, _measurements, %{result: :miss}}
  end

  test "updating a user evicts every cached copy of their identity" do
    user = user_fixture(%{username: "before"})
    first_token = Accounts.create_session(user)
    second_token = Accounts.create_session(user)

    assert {:ok, updated} = Accounts.update_username(user, %{username: "after"})
    assert updated.username == "after"

    assert {:ok, first} = Accounts.fetch_user_by_session_token(first_token)
    assert {:ok, second} = Accounts.fetch_user_by_session_token(second_token)
    assert first.username == "after"
    assert second.username == "after"
    assert_receive {:session_cache, _measurements, %{result: :miss}}
    assert_receive {:session_cache, _measurements, %{result: :miss}}
  end

  test "an expired database session is rejected on a cache miss" do
    user = user_fixture()
    token = Accounts.create_session(user)
    token_hash = hash(token)

    expired_at =
      DateTime.utc_now() |> DateTime.add(-61 * 24 * 3600, :second) |> DateTime.truncate(:second)

    from_session = Repo.get_by!(Session, token_hash: token_hash)
    from_session |> Ecto.Changeset.change(last_used_at: expired_at) |> Repo.update!()
    :ok = SessionCache.evict(token_hash)

    assert :error = Accounts.fetch_user_by_session_token(token)
    assert_receive {:session_cache, _measurements, %{result: :miss}}
  end

  test "unknown tokens are not cached and raw session tokens are never keys" do
    unknown = :crypto.strong_rand_bytes(32)
    size = SessionCache.size()

    assert :error = Accounts.fetch_user_by_session_token(unknown)
    assert SessionCache.size() == size
    refute :ets.member(SessionCache, unknown)
    refute :ets.member(SessionCache, hash(unknown))

    user = user_fixture()
    token = Accounts.create_session(user)

    refute :ets.member(SessionCache, token)
    assert :ets.member(SessionCache, hash(token))
  end

  test "an invalidation rejects a database fill that began in an older generation" do
    user = user_fixture()
    token = Accounts.create_session(user)
    token_hash = hash(token)
    :ok = SessionCache.evict(token_hash)

    assert {:miss, generation} = SessionCache.fetch(token_hash)
    :ok = SessionCache.evict(token_hash)

    assert :stale = SessionCache.put_if_fresh(token_hash, user, generation)
    assert {:miss, _new_generation} = SessionCache.fetch(token_hash)
  end

  test "clear removes entries between SQL sandbox owners" do
    Accounts.create_session(user_fixture())
    assert SessionCache.size() == 1

    assert :ok = SessionCache.clear()
    assert SessionCache.size() == 0
  end

  test "the sweep removes expired entries which receive no more traffic" do
    user = user_fixture()
    token = Accounts.create_session(user)
    :ok = SessionCache.put(hash(token), user, ttl_ms: 0)

    send(SessionCache, :sweep)
    _state = :sys.get_state(SessionCache)

    assert SessionCache.size() == 0
  end

  def handle_cache_event(_event, measurements, metadata, test) do
    send(test, {:session_cache, measurements, metadata})
  end

  def handle_query_event(_event, _measurements, _metadata, test) do
    send(test, :repo_query)
  end

  defp hash(token), do: :crypto.hash(:sha256, token)
end
