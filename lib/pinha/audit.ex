defmodule Pinha.Audit do
  @moduledoc """
  Structured audit attached to the request widelog.

  Every state-changing operation calls `put/3` with the `conn` so the audit
  fields are aggregated into the single widelog line for that request rather
  than emitting a separate line. Both PK (`id`) and stable `uid` are emitted
  for every user reference.
  """

  import Plug.Conn

  alias Pinha.Accounts.User

  @doc "Puts an `audit.*` event onto the request. No separate line is emitted."
  @spec put(Plug.Conn.t(), String.t(), User.t() | nil, map()) :: Plug.Conn.t()
  def put(conn, event, actor, extra \\ %{}) when is_binary(event) do
    audit =
      %{audit_event: "audit.#{event}"}
      |> maybe_put_actor(actor)
      |> Map.merge(extra)

    # Keep a list so a request that triggers two audits (unlikely) keeps both;
    # Observability merges them in order.
    existing = conn.private[:pinha_audit] || []
    put_private(conn, :pinha_audit, existing ++ [audit])
  end

  @doc "Helper to build target fields (both id and uid) for a user."
  @spec target_fields(User.t() | nil, map()) :: map()
  def target_fields(user, extra \\ %{})
  def target_fields(nil, extra), do: extra

  def target_fields(%User{id: id, uid: uid, username: username, email: email}, extra) do
    extra
    |> Map.put(:target_id, id)
    |> Map.put(:target_uid, uid)
    |> maybe_put(:target_username, username)
    |> maybe_put(:target_email, email)
  end

  @doc "Helper to build actor fields (both id and uid)."
  @spec actor_fields(User.t() | nil) :: map()
  def actor_fields(nil), do: %{}

  def actor_fields(%User{id: id, uid: uid}) do
    %{actor_id: id, actor_uid: uid}
  end

  defp maybe_put_actor(fields, nil), do: fields

  defp maybe_put_actor(fields, %User{id: id, uid: uid}) do
    fields |> Map.put(:actor_id, id) |> Map.put(:actor_uid, uid)
  end

  defp maybe_put_actor(fields, actor) when is_map(actor) do
    fields
    |> maybe_put(:actor_id, Map.get(actor, :id) || Map.get(actor, "id"))
    |> maybe_put(:actor_uid, Map.get(actor, :uid) || Map.get(actor, "uid"))
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
