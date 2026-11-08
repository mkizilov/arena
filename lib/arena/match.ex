defmodule Arena.Match do
  @moduledoc """
  Owns one match's lifecycle and broadcasts transitions independently of sockets.

  See DESIGN.md for the public API, timing and leave semantics.
  """
  use GenServer, restart: :temporary

  alias Arena.Game

  @directions [:up, :down, :left, :right]
  @ticks_per_second 15

  @doc "Starts a uniquely registered match under the match supervisor."
  def start_match(id, opts \\ []) when is_binary(id) and byte_size(id) > 0 do
    Arena.Lobby.start_match(id, opts)
  end

  @doc false
  def start_link({id, opts}) do
    GenServer.start_link(__MODULE__, {id, opts}, name: via(id))
  end

  @doc "Returns the PubSub topic for a match ID."
  def topic(id), do: "match:#{id}"

  @doc "Adds a player while the match is waiting or counting down."
  def join(id, player), do: GenServer.call(via(id), {:join, player})

  @doc "Removes a player; leaving a running match forfeits their snake."
  def leave(id, player), do: GenServer.call(via(id), {:leave, player})

  @doc "Buffers a player's latest valid direction until the next tick."
  def input(id, player, direction), do: GenServer.call(via(id), {:input, player, direction})

  @doc "Returns the current lifecycle, player list and game snapshot."
  def snapshot(id), do: GenServer.call(via(id), :snapshot)

  @doc "Advances one running tick when the match was started in manual mode."
  def tick(id), do: GenServer.call(via(id), :tick)

  defp via(id), do: {:via, Registry, {Arena.MatchRegistry, id}}

  @impl true
  def init({id, opts}) do
    seed = Keyword.get_lazy(opts, :seed, fn ->
      {System.monotonic_time(), System.unique_integer([:positive]), :erlang.phash2(id)}
    end)

    players = Keyword.get(opts, :players, [])

    if not is_list(players) or length(players) > 8 or length(Enum.uniq(players)) != length(players) do
      raise ArgumentError, "initial players must be a list of at most eight unique IDs"
    end

    phase = if length(players) >= 2, do: :countdown, else: :waiting

    state = %{
      id: id,
      phase: phase,
      players: players,
      visibility: Keyword.get(opts, :visibility, :public),
      game: nil,
      inputs: %{},
      forfeits: [],
      seed: seed,
      manual: Keyword.get(opts, :manual, false),
      countdown_ms: Keyword.get(opts, :countdown_ms, 3_000),
      idle_ms: Keyword.get(opts, :idle_ms, 60_000),
      grace_ms: Keyword.get(opts, :grace_ms, 10_000),
      timer: nil,
      epoch: nil,
      scheduled_tick: 0
    }

    state =
      if phase == :countdown,
        do: arm(state, :countdown, state.countdown_ms),
        else: arm(state, :idle, state.idle_ms)

    {:ok, state}
  end

  @impl true
  def handle_call(:snapshot, _from, state) do
    {:reply,
     %{phase: state.phase, players: state.players, game: state.game, visibility: state.visibility},
     state}
  end

  def handle_call({:join, player}, _from, state) do
    cond do
      state.phase not in [:waiting, :countdown] ->
        {:reply, {:error, :started}, state}

      player in state.players ->
        {:reply, {:error, :already_joined}, state}

      length(state.players) >= 8 ->
        {:reply, {:error, :full}, state}

      true ->
        state = %{state | players: state.players ++ [player]}

        state =
          cond do
            state.phase == :waiting and length(state.players) >= 2 ->
              state |> set_phase(:countdown) |> arm(:countdown, state.countdown_ms)

            state.phase == :waiting ->
              arm(state, :idle, state.idle_ms)

            true ->
              state
          end

        broadcast_status(state)
        {:reply, :ok, state}
    end
  end

  def handle_call({:leave, player}, _from, state) do
    if player in state.players do
      state = %{state | players: List.delete(state.players, player), inputs: Map.delete(state.inputs, player)}
      state = leave_phase(state, player)
      broadcast_status(state)
      {:reply, :ok, state}
    else
      {:reply, {:error, :not_joined}, state}
    end
  end

  def handle_call({:input, player, direction}, _from, state) do
    cond do
      state.phase != :running -> {:reply, {:error, :not_running}, state}
      player not in state.players -> {:reply, {:error, :not_joined}, state}
      not state.game.snakes[player].alive -> {:reply, {:error, :dead}, state}
      direction not in @directions -> {:reply, {:error, :invalid_direction}, state}
      true -> {:reply, :ok, %{state | inputs: Map.put(state.inputs, player, direction)}}
    end
  end

  def handle_call(:tick, _from, %{manual: true, phase: :running} = state) do
    {:reply, :ok, advance(state)}
  end

  def handle_call(:tick, _from, state), do: {:reply, {:error, :not_manual_running}, state}

  @impl true
  def handle_info({:timer, kind, token}, %{timer: {_ref, token}} = state) do
    state = %{state | timer: nil}

    case kind do
      :idle ->
        {:stop, :normal, state}

      :countdown ->
        game = Game.new(state.players, state.seed)
        state = %{state | game: game, epoch: System.monotonic_time(:millisecond), scheduled_tick: 0}
        state = set_phase(state, :running)
        broadcast_status(state)
        {:noreply, schedule_tick(state)}

      :tick ->
        {:noreply, state |> advance() |> schedule_tick()}

      :shutdown ->
        {:stop, :normal, state}
    end
  end

  def handle_info({:timer, _kind, _token}, state), do: {:noreply, state}

  defp leave_phase(%{phase: :running} = state, player) do
    snake = Map.fetch!(state.game.snakes, player)

    if snake.alive do
      game = %{state.game | snakes: Map.put(state.game.snakes, player, %{snake | alive: false})}
      %{state | game: game, forfeits: state.forfeits ++ [{:died, player}]}
    else
      state
    end
  end

  defp leave_phase(%{phase: :countdown, players: players} = state, _player)
       when length(players) < 2 do
    state |> set_phase(:waiting) |> arm(:idle, state.idle_ms)
  end

  defp leave_phase(%{phase: :waiting} = state, _player), do: arm(state, :idle, state.idle_ms)
  defp leave_phase(state, _player), do: state

  defp advance(state) do
    {game, events} = Game.tick(state.game, state.inputs)
    events = state.forfeits ++ events
    state = %{state | game: game, inputs: %{}, forfeits: []}
    Phoenix.PubSub.broadcast(Arena.PubSub, topic(state.id), {:match_tick, state.id, game, events})

    if game.result do
      state = state |> set_phase(:finished) |> arm(:shutdown, state.grace_ms)
      broadcast_status(state)
      state
    else
      state
    end
  end

  defp schedule_tick(%{manual: true} = state), do: state
  defp schedule_tick(%{phase: phase} = state) when phase != :running, do: state

  defp schedule_tick(state) do
    number = state.scheduled_tick + 1
    deadline = state.epoch + div(number * 1_000, @ticks_per_second)
    delay = max(deadline - System.monotonic_time(:millisecond), 0)
    state |> Map.put(:scheduled_tick, number) |> arm(:tick, delay)
  end

  defp set_phase(state, phase), do: %{state | phase: phase}

  defp arm(state, kind, delay) do
    if state.timer, do: Process.cancel_timer(elem(state.timer, 0))
    token = make_ref()
    ref = Process.send_after(self(), {:timer, kind, token}, delay)
    %{state | timer: {ref, token}}
  end

  defp broadcast_status(state) do
    Phoenix.PubSub.broadcast(
      Arena.PubSub,
      topic(state.id),
      {:match_status, state.id, state.phase, state.players}
    )
  end
end
