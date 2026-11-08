defmodule Arena.Observability do
  @moduledoc "Keeps a bounded, node-local summary for the custom dashboard."
  use GenServer

  @events [
    [:arena, :match, :tick],
    [:arena, :match, :overrun],
    [:arena, :channel, :message],
    [:arena, :matchmaking, :wait]
  ]

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  def update(id, phase, players), do: GenServer.cast(__MODULE__, {:update, id, phase, players})
  def remove(id), do: GenServer.cast(__MODULE__, {:remove, id})
  def snapshot, do: GenServer.call(__MODULE__, :snapshot)

  @doc false
  def handle_event(event, measurements, metadata, pid) do
    GenServer.cast(pid, {:event, event, measurements, metadata})
  end

  @impl true
  def init(:ok) do
    :telemetry.detach(__MODULE__)
    :ok = :telemetry.attach_many(__MODULE__, @events, &__MODULE__.handle_event/4, self())

    matches =
      Arena.MatchStore.states()
      |> Enum.reduce(%{}, fn {id, state}, acc ->
        if Enum.any?(Horde.Registry.lookup(Arena.MatchRegistry, id), fn {pid, _} -> node(pid) == node() end) do
          Map.put(acc, id, population(state.phase, state.game))
        else
          acc
        end
      end)

    state = %{generation: System.unique_integer([:positive, :monotonic]), matches: matches, ticks: 0, overruns: 0, last_tick_us: 0,
      messages_in: 0, messages_out: 0, waits: 0, wait_total_ms: 0}
    emit_population(state, nil)
    {:ok, state}
  end

  @impl true
  def handle_call(:snapshot, _from, state) do
    {:reply, Map.merge(Map.delete(state, :matches), totals(state)), state}
  end

  @impl true
  def handle_cast({:update, id, phase, players}, state) do
    value = if phase == :running, do: %{active: 1, players: players}, else: %{active: 0, players: 0}
    if Map.get(state.matches, id) == value do
      {:noreply, state}
    else
      state = %{state | matches: Map.put(state.matches, id, value)}
      emit_population(state, id)
      {:noreply, state}
    end
  end

  def handle_cast({:remove, id}, state) do
    state = %{state | matches: Map.delete(state.matches, id)}
    emit_population(state, id)
    {:noreply, state}
  end

  def handle_cast({:event, [:arena, :match, :tick], m, _}, state),
    do: {:noreply, %{state | ticks: state.ticks + 1, last_tick_us: m.duration_us}}

  def handle_cast({:event, [:arena, :match, :overrun], _m, _}, state),
    do: {:noreply, %{state | overruns: state.overruns + 1}}

  def handle_cast({:event, [:arena, :channel, :message], m, %{direction: :in}}, state),
    do: {:noreply, %{state | messages_in: state.messages_in + m.count}}

  def handle_cast({:event, [:arena, :channel, :message], m, %{direction: :out}}, state),
    do: {:noreply, %{state | messages_out: state.messages_out + m.count}}

  def handle_cast({:event, [:arena, :matchmaking, :wait], m, _}, state),
    do: {:noreply, %{state | waits: state.waits + 1, wait_total_ms: state.wait_total_ms + m.wait_ms}}

  @impl true
  def terminate(_reason, _state), do: :telemetry.detach(__MODULE__)

  defp population(:running, game) when not is_nil(game) do
    %{active: 1, players: Enum.count(game.snakes, fn {_id, snake} -> snake.alive end)}
  end

  defp population(_, _), do: %{active: 0, players: 0}

  defp totals(state) do
    Enum.reduce(state.matches, %{active_matches: 0, active_players: 0}, fn {_id, entry}, acc ->
      %{active_matches: acc.active_matches + entry.active, active_players: acc.active_players + entry.players}
    end)
  end

  defp emit_population(state, match_id) do
    counts = totals(state)
    :telemetry.execute([:arena, :population], %{matches: counts.active_matches, players: counts.active_players}, %{match_id: match_id})
  end
end
