defmodule Pinha.Mirroring.Push do
  @moduledoc """
  Makes a mirror target's branches and tags equal to a reference snapshot
  with git.

  The target's references are read with `git ls-remote`, compared with the
  snapshot, and written back in two pushes: creations and updates first, then
  deletions, so a renamed branch lands even when deleting the old name is
  refused. Every reference is pushed with its own `--force-with-lease`
  naming the value just read, empty for a creation, so a reference that
  changed on the target after the read is refused rather than overwritten.
  Names conflicted in the snapshot are left at their target value.

  git receives the credential through `GIT_CONFIG_COUNT`, `GIT_CONFIG_KEY_0`,
  and `GIT_CONFIG_VALUE_0` in its environment, never its arguments or a file.
  Nothing kills it on a timer: `http.lowSpeedLimit` and `http.lowSpeedTime`
  make git give up by itself on a stalled connection. Its output is scrubbed
  of the credential and anything token-shaped before it is returned.
  """

  alias Pinha.Config
  alias Pinha.Git
  alias Pinha.Providers.Scrub
  alias Pinha.Providers.Secret
  alias Pinha.Repos.Snapshot

  require OpenTelemetry.Tracer, as: Tracer

  # Bytes per second below which, for `@low_speed_seconds`, git abandons a
  # transfer as stalled.
  @low_speed_limit 1_000
  @low_speed_seconds 60
  @output_limit 4_000

  @type update :: %{ref: String.t(), old: String.t() | nil, new: String.t()}
  @type delete :: %{ref: String.t(), old: String.t()}
  @type plan :: %{updates: [update()], deletes: [delete()], held: [String.t()]}

  @doc """
  What to push so the target's `remote` references equal the snapshot.

  An update with a nil `old` is a creation.
  """
  @spec plan(Snapshot.t(), %{String.t() => String.t()}) :: plan()
  def plan(%Snapshot{refs: refs, conflicted: conflicted}, remote) do
    held = conflicted |> Enum.uniq() |> Enum.sort()

    updates =
      for {ref, new} <- Enum.sort(refs),
          ref not in held,
          Map.get(remote, ref) != new,
          do: %{ref: ref, old: Map.get(remote, ref), new: new}

    deletes =
      for {ref, old} <- Enum.sort(remote),
          not Map.has_key?(refs, ref),
          ref not in held,
          do: %{ref: ref, old: old}

    %{updates: updates, deletes: deletes, held: held}
  end

  @doc "The target's `refs/heads/*` and `refs/tags/*`, name to object ID."
  @spec ls_remote(String.t(), map()) :: {:ok, %{String.t() => String.t()}} | {:error, String.t()}
  def ls_remote(dir, push) do
    case run(dir, ["ls-remote", "--refs", "--heads", "--tags", push.url], push) do
      {:ok, out, _stderr} ->
        refs =
          out
          |> String.split("\n", trim: true)
          |> Enum.flat_map(fn line ->
            case String.split(line, "\t", parts: 2) do
              [oid, "refs/heads/" <> _ = ref] -> [{ref, oid}]
              [oid, "refs/tags/" <> _ = ref] -> [{ref, oid}]
              _ -> []
            end
          end)
          |> Map.new()

        {:ok, refs}

      {:error, _out, message} ->
        {:error, message}
    end
  end

  @doc """
  Pushes creations and updates, then deletions.

  Deletions are skipped when an update was refused, so a branch is never
  removed from the target while its replacement failed to land. Returns `:ok`
  or the combined, scrubbed account of what was refused.
  """
  @spec apply_plan(String.t(), map(), plan()) :: :ok | {:error, String.t()}
  def apply_plan(dir, push, plan) do
    with :ok <- push_updates(dir, push, plan.updates) do
      push_deletes(dir, push, plan.deletes)
    end
  end

  defp push_updates(_dir, _push, []), do: :ok

  defp push_updates(dir, push, updates) do
    leases = Enum.map(updates, &"--force-with-lease=#{&1.ref}:#{&1.old}")
    # No `+` on the refspec: it would force the update whatever the lease
    # said, which is the opposite of what the lease is for.
    refspecs = Enum.map(updates, &"#{&1.new}:#{&1.ref}")
    push(dir, push, leases ++ [push.url | refspecs])
  end

  defp push_deletes(_dir, _push, []), do: :ok

  defp push_deletes(dir, push, deletes) do
    leases = Enum.map(deletes, &"--force-with-lease=#{&1.ref}:#{&1.old}")
    refspecs = Enum.map(deletes, &":#{&1.ref}")
    push(dir, push, leases ++ [push.url | refspecs])
  end

  defp push(dir, push, args) do
    case run(dir, ["push", "--porcelain", "--no-verify" | args], push) do
      {:ok, _out, _stderr} ->
        :ok

      {:error, out, stderr} ->
        {:error, failure_message(out, stderr)}
    end
  end

  # The porcelain lines name each refused reference with git's reason; the
  # remote's own explanation, such as a rule it enforces, is on stderr.
  defp failure_message(out, stderr) do
    refused =
      out
      |> String.split("\n", trim: true)
      |> Enum.flat_map(fn line ->
        case String.split(line, "\t") do
          ["!", from_to, summary | _] -> [ref_name(from_to) <> " " <> summary]
          _ -> []
        end
      end)

    [Enum.join(refused, "\n"), stderr]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join("\n")
    |> case do
      "" -> "git push failed"
      message -> limit(message)
    end
  end

  defp ref_name(from_to) do
    case String.split(from_to, ":", parts: 2) do
      [_from, to] -> to
      [ref] -> ref
    end
  end

  defp run(dir, args, push) do
    args = [
      "-c",
      "http.lowSpeedLimit=#{@low_speed_limit}",
      "-c",
      "http.lowSpeedTime=#{@low_speed_seconds}" | args
    ]

    subcommand = Enum.at(args, 4)
    stderr_path = Git.stderr_path()

    Tracer.with_span "git #{subcommand}",
                     %{attributes: Git.span_attributes(dir, subcommand, args)} do
      try do
        {out, status} =
          System.cmd("/bin/sh", Git.shell_args(Config.git_bin(), args),
            cd: dir,
            env: env(push, stderr_path),
            stderr_to_stdout: false
          )

        stderr = read_output(stderr_path, push)
        out = Scrub.scrub(out, push.secrets)

        if status == 0 do
          {:ok, out, stderr}
        else
          Git.record_failure(status, stderr)
          {:error, out, stderr || "git #{subcommand} exited #{status}"}
        end
      rescue
        # A spawn failure carries the environment it was given in its
        # arguments; none of it is kept.
        _error ->
          Tracer.set_status(OpenTelemetry.status(:error, "could not start git"))
          {:error, "", "could not start git"}
      after
        File.rm(stderr_path)
      end
    end
  end

  defp env(push, stderr_path) do
    Git.env(
      env: [
        {Git.stderr_var(), stderr_path},
        {"GIT_CONFIG_COUNT", "1"},
        {"GIT_CONFIG_KEY_0", "http.extraHeader"},
        {"GIT_CONFIG_VALUE_0", Secret.reveal(push.auth_header)}
      ]
    )
  end

  # Scrubbed before it is truncated, so a cut can never leave half a token
  # that no longer looks like one.
  defp read_output(path, push) do
    case File.read(path) do
      {:ok, text} ->
        text
        |> Git.scrub()
        |> Scrub.scrub(push.secrets)
        |> String.trim()
        |> case do
          "" -> nil
          text -> limit(text)
        end

      {:error, _} ->
        nil
    end
  end

  defp limit(text) when byte_size(text) > @output_limit,
    do: String.slice(text, 0, @output_limit) <> "…"

  defp limit(text), do: text
end
