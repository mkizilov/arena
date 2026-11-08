defmodule Arena.Match do
  @moduledoc """
  Owns one match's lifecycle and broadcasts transitions independently of sockets.

  See DESIGN.md for the public API, timing and leave semantics.
  """
  use GenServer, restart: :transient
  require Logger

  alias Arena.Game

  @directions [:up, :down, :left, :right]
  @ticks_per_second 15

  @doc "Starts a uniquely registered match under the match supervisor."
  def start_match(id, opts \\ []) when is_binary(id) and byte_size(id) > 0 do
    opts =
      Keyword.put_new_lazy(opts, :instance_id, fn ->
        :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)
      end)

    Arena.Lobby.start_match(id, opts)
  end

  @doc false
  def child_spec({id, opts}) do
    %{
      id: {__MODULE__, id},
      start: {__MODULE__, :start_link, [{id, opts}]},
      restart: :transient,
      shutdown: 15_000
    }
  end

  @doc false
  def start_link({id, opts}) do
    GenServer.start_link(__MODULE__, {id, opts}, name: via(id), timeout: 10_000)
  end

  @doc "Returns the PubSub topic for a match ID."
  def topic(id), do: "match:#{id}"

  @doc "Adds a player while the match is waiting or counting down."
  def join(id, player), do: GenServer.call(via(id), {:join, player})

  @doc "Removes a player; leaving a running match forfeits their snake."
  def leave(id, player), do: GenServer.call(via(id), {:leave, player})

  @doc "Attaches a player session, reclaiming their snake during the reconnect grace period."
  def attach(id, player, pid, display_name \\ nil),
    do: GenServer.call(via(id), {:attach, player, pid, display_name})

  @doc "Buffers a player's latest valid direction until the next tick."
  def input(id, player, direction), do: GenServer.call(via(id), {:input, player, direction})

  @doc "Returns the current lifecycle, player list and game snapshot."
  def snapshot(id), do: GenServer.call(via(id), :snapshot)

  @doc "Advances one running tick when the match was started in manual mode."
  def tick(id), do: GenServer.call(via(id), :tick)

  @doc "Stops a match normally, deleting its checkpoint."
  def stop(id), do: GenServer.call(via(id), :stop)

  defp via(id), do: {:via, Horde.Registry, {Arena.MatchRegistry, id}}

  @impl true
  def init({id, opts}) do
    Process.flag(:trap_exit, true)
    Logger.metadata(match_id: id)

    case Arena.MatchStore.get(id, Keyword.fetch!(opts, :instance_id)) do
      {:ok, saved} ->
        case Arena.MatchState.upgrade(saved) do
          {:ok, migrated} ->
            state = restore(migrated)
            checkpoint(state)
            observe(state)
            send(self(), :announce_recovery)
            {:ok, state}

          {:error, reason} ->
            {:stop, reason}
        end

      :new ->
        state = new_state(id, opts)
        checkpoint(state)
        observe(state)
        send(self(), :announce_started)
        {:ok, state}

      :error ->
        {:stop, :checkpoint_unavailable}

      :deleted ->
        :ignore
    end
  end

  defp new_state(id, opts) do
    seed =
      Keyword.get_lazy(opts, :seed, fn ->
        {System.monotonic_time(), System.unique_integer([:positive]), :erlang.phash2(id)}
      end)

    players = Keyword.get(opts, :players, [])

    if not is_list(players) or length(players) > 8 or
         length(Enum.uniq(players)) != length(players) do
      raise ArgumentError, "initial players must be a list of at most eight unique IDs"
    end

    phase = if length(players) >= 2, do: :countdown, else: :waiting

    state = %{
      id: id,
      version: Arena.MatchState.current_version(),
      result_id: Keyword.fetch!(opts, :instance_id),
      phase: phase,
      players: players,
      names: %{},
      visibility: Keyword.get(opts, :visibility, :public),
      game: nil,
      published_game: nil,
      inputs: %{},
      forfeits: [],
      seed: seed,
      manual: Keyword.get(opts, :manual, false),
      countdown_ms: Keyword.get(opts, :countdown_ms, 3_000),
      idle_ms: Keyword.get(opts, :idle_ms, 60_000),
      grace_ms: Keyword.get(opts, :grace_ms, 10_000),
      reconnect_ms: Keyword.get(opts, :reconnect_ms, 10_000),
      connections: %{},
      monitors: %{},
      disconnects: %{},
      disconnect_timers: %{},
      timer: nil,
      timer_kind: nil,
      timer_deadline: nil,
      countdown_ends_at: nil,
      epoch: nil,
      scheduled_tick: 0
    }

    state =
      if phase == :countdown,
        do: arm(state, :countdown, state.countdown_ms),
        else: arm(state, :idle, state.idle_ms)

    state
  end

  @impl true
  def handle_call(:snapshot, _from, state) do
    {:reply, snapshot_state(state), state}
  end

  def handle_call(:stop, _from, state), do: {:stop, :normal, :ok, state}

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

        checkpoint(state)
        broadcast_status(state)
        {:reply, :ok, state}
    end
  end

  def handle_call({:leave, player}, _from, state) do
    if player in state.players do
      state = remove_player(state, player)
      checkpoint(state)
      broadcast_status(state)
      {:reply, :ok, state}
    else
      {:reply, {:error, :not_joined}, state}
    end
  end

  def handle_call({:attach, player, pid, display_name}, _from, state) when is_pid(pid) do
    cond do
      state.phase == :finished ->
        {:reply, {:error, :finished}, state}

      expired?(state, player) ->
        state = remove_player(state, player)
        checkpoint(state)
        broadcast_status(state)
        {:reply, {:error, :expired}, state}

      dead_player?(state, player) ->
        {:reply, {:error, :dead}, state}

      player in state.players ->
        attach_existing(state, player, pid, display_name)

      state.phase not in [:waiting, :countdown] ->
        {:reply, {:error, :started}, state}

      length(state.players) >= 8 ->
        {:reply, {:error, :full}, state}

      true ->
        attach_new(state, player, pid, display_name)
    end
  end

  def handle_call({:input, player, direction}, _from, state) do
    cond do
      state.phase != :running ->
        {:reply, {:error, :not_running}, state}

      player not in state.players ->
        {:reply, {:error, :not_joined}, state}

      Map.has_key?(state.disconnects, player) ->
        {:reply, {:error, :disconnected}, state}

      not state.game.snakes[player].alive ->
        {:reply, {:error, :dead}, state}

      direction not in @directions ->
        {:reply, {:error, :invalid_direction}, state}

      true ->
        state = %{state | inputs: Map.put(state.inputs, player, direction)}
        checkpoint(state)
        {:reply, :ok, state}
    end
  end

  def handle_call(:tick, _from, %{manual: true, phase: :running} = state) do
    {:reply, :ok, advance(state)}
  end

  def handle_call(:tick, _from, state), do: {:reply, {:error, :not_manual_running}, state}

  defp dead_player?(state, player),
    do:
      player in state.players and state.phase == :running and not state.game.snakes[player].alive

  defp attach_existing(state, player, pid, display_name) do
    reconnecting = Map.has_key?(state.disconnects, player)
    state = state |> attach_session(player, pid) |> remember_name(player, display_name)
    checkpoint(state)

    if reconnecting do
      Phoenix.PubSub.broadcast(
        Arena.PubSub,
        topic(state.id),
        {:match_reconnected, state.id, player}
      )
    end

    {:reply, {:ok, snapshot_state(state)}, state}
  end

  defp attach_new(state, player, pid, display_name) do
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

    state = state |> attach_session(player, pid) |> remember_name(player, display_name)
    checkpoint(state)
    broadcast_status(state)
    {:reply, {:ok, snapshot_state(state)}, state}
  end

  @impl true
  def handle_info({:timer, kind, token}, %{timer: {_ref, token}} = state) do
    state = %{state | timer: nil}

    case kind do
      :idle ->
        {:stop, :normal, state}

      :countdown ->
        game = Game.new(state.players, state.seed)

        state = %{
          state
          | game: game,
            published_game: game,
            epoch: System.monotonic_time(:millisecond),
            scheduled_tick: 0
        }

        state = set_phase(state, :running)
        state = schedule_tick(state)
        checkpoint(state)
        broadcast_status(state)
        {:noreply, state}

      :tick ->
        {:noreply, state |> advance() |> schedule_tick()}

      :shutdown ->
        {:stop, :normal, state}
    end
  end

  def handle_info({:timer, _kind, _token}, state), do: {:noreply, state}

  def handle_info(:announce_recovery, state) do
    Phoenix.PubSub.broadcast(
      Arena.PubSub,
      "arena:matches",
      {:match_registered, state.id, self(), :recovered}
    )

    if state.game do
      :ok = Arena.GameUpdates.snapshot(state.id, state.game)
      Arena.Telemetry.channel(:out, "state", state.id, nil, session_count(state))
    end

    if state.phase == :finished, do: Arena.ResultWriter.wake()
    broadcast_status(state)
    {:noreply, state}
  end

  def handle_info(:announce_started, state) do
    Phoenix.PubSub.broadcast(
      Arena.PubSub,
      "arena:matches",
      {:match_registered, state.id, self(), :started}
    )

    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, pid, _reason}, state) do
    case Map.pop(state.monitors, ref) do
      {nil, _} ->
        {:noreply, state}

      {{player, ^pid}, monitors} ->
        sessions = Map.get(state.connections, player, MapSet.new()) |> MapSet.delete(pid)

        connections =
          if MapSet.size(sessions) == 0 do
            Map.delete(state.connections, player)
          else
            Map.put(state.connections, player, sessions)
          end

        state = %{state | monitors: monitors, connections: connections}

        state =
          if MapSet.size(sessions) == 0 and player in state.players and state.phase != :finished do
            deadline = System.monotonic_time(:millisecond) + state.reconnect_ms

            state = %{
              state
              | inputs: Map.delete(state.inputs, player),
                disconnects: Map.put(state.disconnects, player, deadline)
            }

            arm_disconnect(state, player, deadline)
          else
            state
          end

        checkpoint(state)

        if Map.has_key?(state.disconnects, player) do
          Phoenix.PubSub.broadcast(
            Arena.PubSub,
            topic(state.id),
            {:match_disconnected, state.id, player}
          )
        end

        {:noreply, state}
    end
  end

  def handle_info({:disconnect_expired, player, token}, state) do
    case Map.get(state.disconnect_timers, player) do
      {_ref, ^token} ->
        if expired?(state, player) and not Map.has_key?(state.connections, player) do
          state = remove_player(state, player)
          checkpoint(state)
          broadcast_status(state)
          {:noreply, state}
        else
          {:noreply, state}
        end

      _ ->
        {:noreply, state}
    end
  end

  @impl true
  def code_change({:down, _version}, _state, _extra), do: {:error, :unsupported_downgrade}
  def code_change(_old_version, state, _extra), do: Arena.MatchState.upgrade(state)

  @impl true
  def terminate(reason, state) do
    if reason == :normal do
      Arena.MatchStore.delete(state.id)
    end

    if reason in [:normal, :shutdown] or match?({:shutdown, _}, reason) do
      Arena.Observability.remove(state.id)
    end

    :ok
  end

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
    started = System.monotonic_time(:nanosecond)
    tick_started_at_ms = System.system_time(:millisecond)
    previous_count = active_players(state)
    {game, events} = Game.tick(state.game, state.inputs)
    events = state.forfeits ++ events
    previous = state.published_game
    state = %{state | game: game, published_game: game, inputs: %{}, forfeits: []}

    state =
      if game.result,
        do: state |> set_phase(:finished) |> arm(:shutdown, state.grace_ms),
        else: state

    if game.result do
      result = Arena.Results.build(state.id, state.result_id, game, state.names)
      :ok = Arena.MatchStore.finish(state.id, checkpoint_data(state), result)
      Arena.ResultWriter.wake()
    else
      checkpoint(state)
    end

    :ok = Arena.GameUpdates.publish(state.id, previous, game, events, tick_started_at_ms)

    Arena.Telemetry.channel(
      :out,
      Arena.GameUpdates.event(game.tick),
      state.id,
      nil,
      session_count(state)
    )

    if game.result, do: broadcast_status(state)
    if is_nil(game.result) and active_players(state) != previous_count, do: observe(state)
    elapsed = max(System.monotonic_time(:nanosecond) - started, 0)
    Arena.Telemetry.tick(state.id, game.tick, elapsed)
    state
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
    deadline = System.monotonic_time(:millisecond) + delay

    %{
      state
      | timer: {ref, token},
        timer_kind: kind,
        timer_deadline: deadline,
        countdown_ends_at: if(kind == :countdown, do: deadline, else: nil)
    }
  end

  defp countdown_remaining(%{phase: :countdown, countdown_ends_at: deadline})
       when is_integer(deadline),
       do: max(deadline - System.monotonic_time(:millisecond), 0)

  defp countdown_remaining(_state), do: nil

  defp snapshot_state(state) do
    %{
      phase: state.phase,
      players: state.players,
      game: state.game,
      visibility: state.visibility,
      countdown_ms: countdown_remaining(state)
    }
  end

  defp checkpoint(state) do
    :ok = Arena.MatchStore.put(state.id, checkpoint_data(state))
  end

  defp checkpoint_data(state) do
    state
    |> Map.merge(%{timer: nil, monitors: %{}, disconnect_timers: %{}})
    |> Map.put(:checkpoint_node, node())
    |> Map.put(
      :checkpoint_offset_ms,
      System.system_time(:millisecond) - System.monotonic_time(:millisecond)
    )
  end

  defp remember_name(state, player, display_name) when is_binary(display_name),
    do: %{state | names: Map.put(state.names, player, display_name)}

  defp remember_name(state, _player, _display_name), do: state

  defp restore(saved) do
    saved = translate_deadlines(saved)
    state = %{saved | timer: nil, monitors: %{}, disconnect_timers: %{}}

    state =
      Enum.reduce(state.connections, state, fn {player, pids}, acc ->
        Enum.reduce(pids, acc, fn pid, acc ->
          ref = Process.monitor(pid)
          %{acc | monitors: Map.put(acc.monitors, ref, {player, pid})}
        end)
      end)

    state =
      Enum.reduce(state.disconnects, state, fn {player, deadline}, acc ->
        arm_disconnect(acc, player, deadline)
      end)

    cond do
      state.phase == :running ->
        state = %{state | epoch: System.monotonic_time(:millisecond), scheduled_tick: 0}
        schedule_tick(state)

      state.timer_kind in [:idle, :countdown, :shutdown] and is_integer(state.timer_deadline) ->
        delay = max(state.timer_deadline - System.monotonic_time(:millisecond), 0)
        arm(state, state.timer_kind, delay)

      true ->
        state
    end
  end

  defp translate_deadlines(%{checkpoint_node: source, checkpoint_offset_ms: offset} = saved)
       when source != node() do
    shift = offset - (System.system_time(:millisecond) - System.monotonic_time(:millisecond))

    remotes =
      Map.new(saved.connections, fn {player, pids} ->
        {player, MapSet.filter(pids, &(node(&1) != source))}
      end)

    disconnects = Map.new(saved.disconnects, fn {id, deadline} -> {id, deadline + shift} end)
    now = System.monotonic_time(:millisecond)

    disconnects =
      Enum.reduce(remotes, disconnects, fn {player, pids}, acc ->
        if MapSet.size(pids) == 0 and player in saved.players and saved.phase != :finished do
          Map.put_new(acc, player, now + saved.reconnect_ms)
        else
          acc
        end
      end)

    inputs = Enum.reduce(Map.keys(disconnects), saved.inputs, &Map.delete(&2, &1))

    saved
    |> Map.put(:connections, Map.reject(remotes, fn {_id, pids} -> MapSet.size(pids) == 0 end))
    |> Map.put(:disconnects, disconnects)
    |> Map.put(:inputs, inputs)
    |> Map.update!(:timer_deadline, &shift_deadline(&1, shift))
    |> Map.update!(:countdown_ends_at, &shift_deadline(&1, shift))
  end

  defp translate_deadlines(saved), do: saved
  defp shift_deadline(nil, _shift), do: nil
  defp shift_deadline(value, shift), do: value + shift

  defp attach_session(state, player, pid) do
    state = cancel_disconnect(state, player)
    sessions = Map.get(state.connections, player, MapSet.new())

    if MapSet.member?(sessions, pid) do
      state
    else
      ref = Process.monitor(pid)

      %{
        state
        | connections: Map.put(state.connections, player, MapSet.put(sessions, pid)),
          monitors: Map.put(state.monitors, ref, {player, pid})
      }
    end
  end

  defp arm_disconnect(state, player, deadline) do
    token = make_ref()
    delay = max(deadline - System.monotonic_time(:millisecond), 0)
    ref = Process.send_after(self(), {:disconnect_expired, player, token}, delay)
    %{state | disconnect_timers: Map.put(state.disconnect_timers, player, {ref, token})}
  end

  defp cancel_disconnect(state, player) do
    {timer, timers} = Map.pop(state.disconnect_timers, player)
    if timer, do: Process.cancel_timer(elem(timer, 0))
    %{state | disconnect_timers: timers, disconnects: Map.delete(state.disconnects, player)}
  end

  defp expired?(state, player) do
    case Map.get(state.disconnects, player) do
      nil -> false
      deadline -> System.monotonic_time(:millisecond) >= deadline
    end
  end

  defp remove_player(state, player) do
    state = cancel_disconnect(state, player)

    monitors =
      Enum.reduce(state.monitors, %{}, fn {ref, {owner, pid}}, acc ->
        if owner == player do
          Process.demonitor(ref, [:flush])
          acc
        else
          Map.put(acc, ref, {owner, pid})
        end
      end)

    state = %{
      state
      | players: List.delete(state.players, player),
        inputs: Map.delete(state.inputs, player),
        connections: Map.delete(state.connections, player),
        monitors: monitors
    }

    leave_phase(state, player)
  end

  defp broadcast_status(state) do
    observe(state)

    Phoenix.PubSub.broadcast(
      Arena.PubSub,
      topic(state.id),
      {:match_status, state.id, state.phase, state.players}
    )
  end

  defp observe(state),
    do: Arena.Observability.update(state.id, state.phase, active_players(state))

  defp active_players(%{phase: :running, game: game}) when not is_nil(game),
    do: Enum.count(game.snakes, fn {_id, snake} -> snake.alive end)

  defp active_players(_state), do: 0

  defp session_count(state),
    do:
      Enum.reduce(state.connections, 0, fn {_id, sessions}, total ->
        total + MapSet.size(sessions)
      end)
end
