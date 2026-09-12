defmodule Pinha.Providers do
  @moduledoc """
  The forges Pinha integrates with, and the rules for reaching them.

  Providers are modules implementing `Pinha.Providers.Provider`, listed in
  the `:providers` application environment. An unconfigured provider is left
  out of `configured/0` and offers no capabilities, so the UI shows no
  controls for it.

  Work that holds a provider credential runs through `sensitive/2`, in a
  process hidden from runtime introspection, so a request process never holds
  one.
  """

  alias Pinha.Providers.Error
  alias Pinha.Providers.EventWorker

  require Logger

  @default_providers [Pinha.Providers.GitHub]

  @doc "Every provider module, configured or not."
  @spec all() :: [module()]
  def all, do: Application.get_env(:pinha, :providers, @default_providers)

  @doc "Providers the operator configured."
  @spec configured() :: [module()]
  def configured, do: Enum.filter(all(), & &1.configured?())

  @doc "A configured provider by its name."
  @spec fetch(String.t()) :: {:ok, module()} | :error
  def fetch(name) when is_binary(name) do
    case Enum.find(configured(), &(&1.name() == name)) do
      nil -> :error
      provider -> {:ok, provider}
    end
  end

  def fetch(_name), do: :error

  @doc "The module implementing `capability` for a configured provider."
  @spec capability(module() | String.t(), module()) :: {:ok, module()} | :error
  def capability(provider, capability) when is_binary(provider) do
    with {:ok, provider} <- fetch(provider), do: capability(provider, capability)
  end

  def capability(provider, capability) when is_atom(provider) do
    if provider.configured?() do
      Map.fetch(provider.capabilities(), capability)
    else
      :error
    end
  end

  @doc "Configured providers implementing `capability`."
  @spec with_capability(module()) :: [module()]
  def with_capability(capability) do
    Enum.filter(configured(), &Map.has_key?(&1.capabilities(), capability))
  end

  @doc "Modules that receive provider events, from the `:provider_subscribers` environment."
  @spec subscribers() :: [module()]
  def subscribers, do: Application.get_env(:pinha, :provider_subscribers, [])

  @doc """
  Hands `event` to every subscriber, each as its own background job.

  Called inside the caller's transaction when there is one, so an event is
  delivered exactly when what caused it is committed.
  """
  @spec dispatch(String.t(), map()) :: :ok
  def dispatch(provider, event) when is_binary(provider) and is_map(event) do
    jobs =
      for subscriber <- subscribers() do
        EventWorker.new(%{
          "provider" => provider,
          "subscriber" => inspect(subscriber),
          "event" => event
        })
      end

    Oban.insert_all(jobs)
    :ok
  end

  @doc """
  Runs `fun` in a process hidden from runtime introspection and returns its
  result.

  The caller waits, but never sees the credentials `fun` creates. An
  exception inside is logged by its module name only and becomes a transient
  error, since its message or stacktrace could carry a credential.
  """
  @spec sensitive((-> result), timeout()) :: result | {:error, Error.t()} when result: term()
  def sensitive(fun, timeout \\ 60_000) when is_function(fun, 0) do
    task =
      Task.Supervisor.async_nolink(Pinha.TaskSupervisor, fn ->
        Process.flag(:sensitive, true)
        guarded(fun)
      end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      {:exit, _reason} -> {:error, Error.transient("the provider request failed")}
      nil -> {:error, Error.transient("the provider did not answer in time")}
    end
  end

  @doc """
  Runs `fun`, turning an exception into a transient error without its
  message.

  For processes already marked sensitive, such as a job.
  """
  @spec guarded((-> result)) :: result | {:error, Error.t()} when result: term()
  def guarded(fun) do
    fun.()
  rescue
    error ->
      Logger.error("provider work raised #{inspect(error.__struct__)}")
      {:error, Error.transient("unexpected error while talking to the provider")}
  catch
    kind, _reason ->
      Logger.error("provider work failed with #{kind}")
      {:error, Error.transient("unexpected error while talking to the provider")}
  end
end
