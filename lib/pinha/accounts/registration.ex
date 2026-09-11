defmodule Pinha.Accounts.Registration do
  @moduledoc """
  The authorizations that admit a registration ceremony, held in memory.

  Two of them live here. A node that starts with no users mints a claim token
  and writes the claim URL on stdout, which is how the operator, and nobody
  else, gets the first account. A user who lost every passkey is let back in
  by the operator from the release console:

      Pinha.Accounts.Registration.authorize("someone@example.com")

  Neither is written down. Both last fifteen minutes, both are spent once, and
  both die with the node, so there is nothing persistent to steal.
  """

  use GenServer

  require Logger

  @window_seconds 900
  @token_bytes 32

  def start_link(opts),
    do: GenServer.start_link(__MODULE__, :ok, Keyword.put_new(opts, :name, __MODULE__))

  @doc "Mints a claim token, replacing any outstanding one, and returns its URL."
  @spec claim() :: String.t()
  def claim, do: GenServer.call(__MODULE__, :claim)

  @doc "Whether `token` is the claim token this node is holding."
  @spec claim?(String.t()) :: boolean()
  def claim?(token) when is_binary(token), do: GenServer.call(__MODULE__, {:claim?, token})

  @doc "Spends the claim token, so one token admits one registration."
  @spec consume_claim(String.t()) :: boolean()
  def consume_claim(token) when is_binary(token),
    do: GenServer.call(__MODULE__, {:consume_claim, token})

  @doc "Lets `email` register one more passkey within the next fifteen minutes."
  @spec authorize(String.t()) :: :ok
  def authorize(email) when is_binary(email) do
    GenServer.call(__MODULE__, {:authorize, normalize(email)})
  end

  @doc "Whether a recovery ceremony for `email` is currently authorized."
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
  def init(:ok), do: {:ok, %{claim: nil, recoveries: %{}}, {:continue, :claim_fresh_server}}

  # A server with no users belongs to nobody, so the operator who started it
  # reads the claim URL out of the logs they are already watching.
  @impl true
  def handle_continue(:claim_fresh_server, state) do
    if Application.get_env(:pinha, :claim_on_boot, true) and fresh_server?() do
      {token, state} = mint(state)
      Logger.info("no users yet: claim this server at #{url(token)}")
      {:noreply, state}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_call(:claim, _from, state) do
    {token, state} = mint(state)
    {:reply, url(token), state}
  end

  def handle_call({:claim?, token}, _from, state) do
    {:reply, holds_claim?(state, token), state}
  end

  def handle_call({:consume_claim, token}, _from, state) do
    if holds_claim?(state, token),
      do: {:reply, true, %{state | claim: nil}},
      else: {:reply, false, state}
  end

  def handle_call({:authorize, email}, _from, state) do
    {:reply, :ok, update_in(state.recoveries, &Map.put(purge(&1), email, deadline()))}
  end

  def handle_call({:authorized?, email}, _from, state) do
    state = update_in(state.recoveries, &purge/1)
    {:reply, Map.has_key?(state.recoveries, email), state}
  end

  def handle_call({:consume, email}, _from, state) do
    state = update_in(state.recoveries, &purge/1)
    held? = Map.has_key?(state.recoveries, email)
    {:reply, held?, update_in(state.recoveries, &Map.delete(&1, email))}
  end

  defp mint(state) do
    token = Base.url_encode64(:crypto.strong_rand_bytes(@token_bytes), padding: false)
    {token, %{state | claim: {token, deadline()}}}
  end

  # The comparison is constant time because the token is a secret presented by
  # whoever is asking, the same as every other token here.
  defp holds_claim?(%{claim: {held, deadline}}, presented) do
    deadline > System.monotonic_time(:second) and
      byte_size(held) == byte_size(presented) and
      :crypto.hash_equals(held, presented)
  end

  defp holds_claim?(%{claim: nil}, _presented), do: false

  defp fresh_server? do
    Pinha.Accounts.count_users() == 0
  rescue
    # A database that is not up yet is no reason to refuse to boot.
    error ->
      Logger.warning("cannot tell whether the server has users: #{Exception.message(error)}")
      false
  end

  defp url(token), do: "#{Pinha.Config.base_url()}/signup?claim=#{token}"

  defp purge(recoveries) do
    now = System.monotonic_time(:second)
    Map.filter(recoveries, fn {_email, deadline} -> deadline > now end)
  end

  defp deadline, do: System.monotonic_time(:second) + @window_seconds

  defp normalize(email), do: email |> String.trim() |> String.downcase()
end
