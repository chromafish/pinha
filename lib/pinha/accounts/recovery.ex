defmodule Pinha.Accounts.Recovery do
  @moduledoc """
  The way back in for a user who lost every passkey.

  The operator authorizes one registration ceremony from the release console:

      Pinha.Accounts.Recovery.authorize("someone@example.com")

  The authorization lives here, in memory, for fifteen minutes, and dies with
  the node. Nothing is written down, so there is nothing to steal later.
  """

  use GenServer

  @window_seconds 900

  def start_link(opts),
    do: GenServer.start_link(__MODULE__, :ok, Keyword.put_new(opts, :name, __MODULE__))

  @doc "Lets `email` register one more passkey within the next fifteen minutes."
  @spec authorize(String.t()) :: :ok
  def authorize(email) when is_binary(email) do
    GenServer.call(__MODULE__, {:authorize, normalize(email)})
  end

  @doc "Whether a ceremony for `email` is currently authorized."
  @spec authorized?(String.t()) :: boolean()
  def authorized?(email) when is_binary(email) do
    GenServer.call(__MODULE__, {:authorized?, normalize(email)})
  end

  @doc "Spends the authorization, so one authorization admits one passkey."
  @spec consume(String.t()) :: boolean()
  def consume(email) when is_binary(email) do
    GenServer.call(__MODULE__, {:consume, normalize(email)})
  end

  @impl true
  def init(:ok), do: {:ok, %{}}

  @impl true
  def handle_call({:authorize, email}, _from, state) do
    {:reply, :ok, Map.put(purge(state), email, deadline())}
  end

  def handle_call({:authorized?, email}, _from, state) do
    state = purge(state)
    {:reply, Map.has_key?(state, email), state}
  end

  def handle_call({:consume, email}, _from, state) do
    state = purge(state)
    {:reply, Map.has_key?(state, email), Map.delete(state, email)}
  end

  defp purge(state) do
    now = System.monotonic_time(:second)
    Map.filter(state, fn {_email, deadline} -> deadline > now end)
  end

  defp deadline, do: System.monotonic_time(:second) + @window_seconds

  defp normalize(email), do: email |> String.trim() |> String.downcase()
end
