defmodule Arena.Matchmaker do
  @moduledoc "Quick-play queue and private room creation."
  use GenServer

  alias Arena.Match

  @wait_ms 10_000

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, if(name, do: [name: name], else: []))
  end

  @doc "Creates a match through the lobby."
  def start_match(id, opts \\ []), do: Match.start_match(id, opts)

  @doc "Queues the calling process for quick play under a unique player ID."
  def quick_play(player, server \\ __MODULE__), do: GenServer.call(server, {:queue, player, self()}, 30_000)

  @doc "Removes the caller's player from the queue."
  def cancel(player, server \\ __MODULE__), do: GenServer.call(server, {:cancel, player, self()})

  @doc "Returns queued player IDs in arrival order."
  def queued(server \\ __MODULE__), do: GenServer.call(server, :queued)

  @doc "Advances the controllable clock of a manual-clock matchmaker."
  def advance(server, milliseconds) when is_integer(milliseconds) and milliseconds >= 0,
    do: GenServer.call(server, {:advance, milliseconds})

  @doc "Creates a private room and joins its creator, returning its short code."
  def create_private(player), do: create_private_room(player, 10)

  @doc "Joins a private room by its case-insensitive code."
  def join_private(code, player) when is_binary(code) do
    code = String.upcase(code)

    if Regex.match?(~r/\A[0-9A-F]{8}\z/, code) do
      id = "room-" <> code

      try do
        case Match.snapshot(id) do
          %{visibility: :private} -> Match.join(id, player)
          _ -> {:error, :not_found}
        end
      catch
        :exit, _reason -> {:error, :not_found}
      end
    else
      {:error, :not_found}
    end
  end

  @impl true
  def init(opts) do
    {:ok, %{queue: [], deadline: nil, timer: nil, clock: Keyword.get(opts, :clock, :system), now: 0}}
  end

  @impl true
  def handle_call(:queued, _from, state) do
    state = maybe_match(state)
    {:reply, Enum.map(state.queue, & &1.player), state}
  end

  def handle_call({:queue, player, pid}, _from, state) do
    state = maybe_match(state)

    if Enum.any?(state.queue, &(&1.player == player)) do
      {:reply, {:error, :already_queued}, state}
    else
      entry = %{player: player, pid: pid, ref: Process.monitor(pid), joined_at: now(state)}
      state = %{state | queue: state.queue ++ [entry]}
      state = if state.deadline, do: state, else: start_wait(state)
      {:reply, :ok, maybe_match(state)}
    end
  end

  def handle_call({:cancel, player, pid}, _from, state) do
    case Enum.find(state.queue, &(&1.player == player and &1.pid == pid)) do
      nil ->
        {:reply, {:error, :not_queued}, state}

      entry ->
        Process.demonitor(entry.ref, [:flush])
        state = %{state | queue: List.delete(state.queue, entry)} |> reset_if_empty()
        {:reply, :ok, maybe_match(state)}
    end
  end

  def handle_call({:advance, milliseconds}, _from, %{clock: :manual} = state) do
    state = %{state | now: state.now + milliseconds}
    {:reply, :ok, maybe_match(state)}
  end

  def handle_call({:advance, _}, _from, state), do: {:reply, {:error, :not_manual}, state}

  @impl true
  def handle_info({:wait_expired, token}, %{timer: {_ref, token}} = state) do
    {:noreply, maybe_match(%{state | timer: nil})}
  end

  def handle_info({:wait_expired, _token}, state), do: {:noreply, state}

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    queue = Enum.reject(state.queue, &(&1.ref == ref))
    state = %{state | queue: queue} |> reset_if_empty()
    {:noreply, maybe_match(state)}
  end

  defp start_wait(state) do
    deadline = now(state) + @wait_ms

    if state.clock == :manual do
      %{state | deadline: deadline}
    else
      token = make_ref()
      ref = Process.send_after(self(), {:wait_expired, token}, @wait_ms)
      %{state | deadline: deadline, timer: {ref, token}}
    end
  end

  defp now(%{clock: :manual, now: now}), do: now
  defp now(_state), do: System.monotonic_time(:millisecond)

  defp maybe_match(state) do
    {live, dead} = Enum.split_with(state.queue, &Process.alive?(&1.pid))
    Enum.each(dead, &Process.demonitor(&1.ref, [:flush]))
    state = %{state | queue: live} |> reset_if_empty()
    count = length(state.queue)

    if count >= 8 or (count >= 2 and now(state) >= state.deadline) do
      create_quick_match(state)
    else
      state
    end
  end

  defp create_quick_match(state) do
    {group, remaining} = Enum.split(state.queue, 8)
    id = "quick-#{System.unique_integer([:positive, :monotonic])}"
    players = Enum.map(group, & &1.player)

    case Match.start_match(id, players: players) do
      {:ok, _pid} ->
        Enum.each(group, fn entry ->
          Process.demonitor(entry.ref, [:flush])
          Arena.Telemetry.matchmaking(id, entry.player, max(now(state) - entry.joined_at, 0))
          send(entry.pid, {:match_found, id, entry.player})
        end)

        state = cancel_timer(%{state | queue: remaining, deadline: nil})
        if remaining == [], do: state, else: state |> start_wait() |> maybe_match()

      {:error, reason} ->
        Enum.each(group, &send(&1.pid, {:matchmaking_error, &1.player, reason}))
        retry(state)
    end
  end

  defp reset_if_empty(%{queue: []} = state), do: cancel_timer(%{state | deadline: nil})
  defp reset_if_empty(state), do: state

  defp cancel_timer(%{timer: {ref, _token}} = state) do
    Process.cancel_timer(ref)
    %{state | timer: nil}
  end

  defp cancel_timer(state), do: state

  defp retry(state) do
    state = cancel_timer(state)

    if state.clock == :manual do
      state
    else
      token = make_ref()
      ref = Process.send_after(self(), {:wait_expired, token}, 1_000)
      %{state | timer: {ref, token}}
    end
  end

  defp create_private_room(_player, 0), do: {:error, :code_unavailable}

  defp create_private_room(player, attempts) do
    code = :crypto.strong_rand_bytes(4) |> Base.encode16()

    case Match.start_match("room-" <> code, players: [player], visibility: :private) do
      {:ok, _pid} -> {:ok, code}
      {:error, {:already_started, _pid}} -> create_private_room(player, attempts - 1)
      error -> error
    end
  end
end
