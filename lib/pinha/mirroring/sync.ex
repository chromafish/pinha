defmodule Pinha.Mirroring.Sync do
  @moduledoc """
  One sync of one mirror.

  A sync holds the repository's sync lock for its whole run, so syncs of one
  repository never overlap; it holds no repository lock. It runs the
  connection check, lets the provider prepare a push with a credential scoped
  to the target, takes one reference snapshot, and makes the target equal to
  it with `Pinha.Mirroring.Push`.

  The outcome is recorded only when no sync of a newer snapshot has already
  recorded success. A terminal failure disables the mirror with its reason; a
  transient one leaves it active. Each sync writes one widelog line and one
  span.
  """

  alias Pinha.Mirroring
  alias Pinha.Mirroring.Mirror
  alias Pinha.Mirroring.Push
  alias Pinha.Providers.Error
  alias Pinha.Repos
  alias Pinha.Widelog

  require OpenTelemetry.Tracer, as: Tracer

  @doc """
  Runs a sync of the mirror with `mirror_id`, started by `trigger`.

  Returns the outcome: `:synced`, `:skipped` for a mirror that is gone or not
  active, or `{:failed, kind, message}`.
  """
  @spec run(integer(), String.t()) :: :synced | :skipped | {:failed, Error.kind(), String.t()}
  def run(mirror_id, trigger) do
    started = System.monotonic_time()

    Tracer.with_span "mirror sync", %{attributes: [{"mirror.trigger", trigger}]} do
      case Mirroring.get(mirror_id) do
        %Mirror{state: "active"} = mirror ->
          Mirroring.with_sync_lock(mirror.repo_id, fn ->
            Mirroring.announce(mirror.repo_id, :started)

            try do
              # Re-read under the lock: a sync that waited may find the mirror
              # disabled by the one before it.
              case Mirroring.get(mirror_id) do
                %Mirror{state: "active"} = mirror -> sync(mirror, trigger, started)
                _ -> report(mirror, trigger, :skipped, %{}, started)
              end
            after
              Mirroring.announce(mirror.repo_id, :finished)
            end
          end)

        mirror ->
          report(mirror, trigger, :skipped, %{}, started)
      end
    end
  end

  defp sync(mirror, trigger, started) do
    # A failure found before the snapshot is dated by when the sync began, so
    # it is not recorded over a success that was taken after it.
    began_at = DateTime.utc_now()

    with {:ok, repo, account, capability} <- Mirroring.check_connection(mirror),
         {:ok, push} <- capability.prepare_sync(mirror, account),
         {:ok, snapshot} <- snapshot(repo) do
      mirror = %{mirror | target_name: push.target_name, target_url: push.target_url}

      case push_snapshot(repo, push, snapshot, capability) do
        {:ok, plan} ->
          Mirroring.record_success(mirror, snapshot, plan.held, push)
          report(mirror, trigger, :synced, counts(plan), started)

        {:error, %Error{} = error, plan} ->
          Mirroring.record_failure(mirror, snapshot.taken_at, error)
          report(mirror, trigger, failed(error), counts(plan), started)
      end
    else
      {:error, %Error{} = error} ->
        Mirroring.record_failure(mirror, began_at, error)
        report(mirror, trigger, failed(error), %{}, started)
    end
  end

  defp snapshot(repo) do
    case Repos.snapshot(repo) do
      {:ok, snapshot} -> {:ok, snapshot}
      {:error, _} -> {:error, Error.transient("could not read the repository's references")}
    end
  end

  defp push_snapshot(repo, push, snapshot, capability) do
    case Push.ls_remote(repo.dir, push) do
      {:ok, remote} ->
        plan = Push.plan(snapshot, remote)

        case Push.apply_plan(repo.dir, push, plan) do
          :ok -> {:ok, plan}
          {:error, message} -> {:error, push_error(capability, message), plan}
        end

      {:error, message} ->
        {:error, push_error(capability, message), nil}
    end
  end

  defp push_error(capability, message) do
    case capability.push_failure(message) do
      {:terminal, reason} -> Error.terminal(reason, message)
      :transient -> Error.transient(message)
    end
  end

  defp failed(%Error{kind: kind, message: message}), do: {:failed, kind, message}

  defp counts(nil), do: %{}

  defp counts(plan) do
    %{
      refs_updated: Enum.count(plan.updates, & &1.old),
      refs_created: Enum.count(plan.updates, &is_nil(&1.old)),
      refs_deleted: length(plan.deletes),
      refs_held: length(plan.held)
    }
  end

  defp report(mirror, trigger, outcome, counts, started) do
    duration_ms =
      (System.monotonic_time() - started)
      |> System.convert_time_unit(:native, :microsecond)
      |> Kernel./(1000)
      |> Float.round(3)

    {outcome_name, error} =
      case outcome do
        {:failed, kind, message} -> {"failed_#{kind}", message}
        other -> {Atom.to_string(other), nil}
      end

    fields =
      %{
        event: "mirror.sync",
        repo: mirror && mirror.repo_name,
        repo_id: mirror && mirror.repo_id,
        mirror_id: mirror && mirror.id,
        provider: mirror && mirror.provider,
        target: mirror && mirror.target_name,
        trigger: trigger,
        outcome: outcome_name,
        duration_ms: duration_ms,
        error: error
      }
      |> Map.merge(counts)

    Tracer.set_attributes(
      fields
      |> Map.delete(:event)
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Enum.map(fn {key, value} -> {"mirror.#{key}", value} end)
    )

    if error do
      Tracer.set_attribute("error", true)
      Tracer.set_status(OpenTelemetry.status(:error, error))
    end

    Widelog.write(fields)
    outcome
  end
end
