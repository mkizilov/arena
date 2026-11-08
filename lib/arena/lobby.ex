defmodule Arena.Lobby do
  @moduledoc "Tracks supervised matches and publishes the public lobby."
  use GenServer

  alias Arena.Match

  @topic "lobby"

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @doc "Starts and tracks a match. Use `Arena.Match.start_match/2` as the public entry point."
  def start_match(id, opts), do: GenServer.call(__MODULE__, {:start_match, id, opts})

  @doc "Returns the sorted IDs of currently live matches."
  def matches, do: GenServer.call(__MODULE__, :matches)

  @doc "Returns public waiting or countdown matches with available capacity."
  def open_matches, do: GenServer.call(__MODULE__, :open_matches)

  @doc "Returns the PubSub topic for lobby snapshots."
  def topic, do: @topic

  @impl true
  def init(:ok) do
    matches =
      Arena.MatchSupervisor
      |> DynamicSupervisor.which_children()
      |> Enum.reduce(%{}, fn
        {_, pid, _, _}, matches when is_pid(pid) ->
          case Registry.keys(Arena.MatchRegistry, pid) do
            [id] ->
              Phoenix.PubSub.subscribe(Arena.PubSub, Match.topic(id))
              Map.put(matches, id, track(pid))

            [] ->
              matches
          end

        _, matches ->
          matches
      end)

    publish(matches)
    {:ok, matches}
  end

  @impl true
  def handle_call(:matches, _from, matches) do
    ids = matches |> Enum.filter(fn {_, entry} -> Process.alive?(entry.pid) end) |> Enum.map(&elem(&1, 0)) |> Enum.sort()
    {:reply, ids, matches}
  end

  def handle_call(:open_matches, _from, matches), do: {:reply, open(matches), matches}

  def handle_call({:start_match, id, opts}, _from, matches) do
    case Map.fetch(matches, id) do
      {:ok, entry} ->
        {:reply, {:error, {:already_started, entry.pid}}, matches}

      :error ->
        :ok = Phoenix.PubSub.subscribe(Arena.PubSub, Match.topic(id))

        case DynamicSupervisor.start_child(Arena.MatchSupervisor, {Match, {id, opts}}) do
          {:ok, pid} ->
            matches = Map.put(matches, id, track(pid))
            publish(matches)
            {:reply, {:ok, pid}, matches}

          error ->
            Phoenix.PubSub.unsubscribe(Arena.PubSub, Match.topic(id))
            {:reply, error, matches}
        end
    end
  end

  @impl true
  def handle_info({:match_status, id, _phase, _players}, matches) do
    matches =
      case Map.fetch(matches, id) do
        {:ok, entry} -> Map.put(matches, id, %{entry | snapshot: snapshot(entry.pid)})
        :error -> matches
      end

    publish(matches)
    {:noreply, matches}
  end

  def handle_info({:match_tick, _id, _game, _events}, matches), do: {:noreply, matches}
  def handle_info({:match_ended_unexpectedly, _id}, matches), do: {:noreply, matches}

  def handle_info({:DOWN, ref, :process, pid, reason}, matches) do
    case Enum.find(matches, fn {_id, entry} -> entry.pid == pid and entry.ref == ref end) do
      {id, _} ->
        if reason not in [:normal, :shutdown] and not match?({:shutdown, _}, reason) do
          Phoenix.PubSub.broadcast(Arena.PubSub, Match.topic(id), {:match_ended_unexpectedly, id})
        end

        Phoenix.PubSub.unsubscribe(Arena.PubSub, Match.topic(id))
        matches = Map.delete(matches, id)
        publish(matches)
        {:noreply, matches}

      nil ->
        {:noreply, matches}
    end
  end

  defp track(pid), do: %{pid: pid, ref: Process.monitor(pid), snapshot: snapshot(pid)}

  defp snapshot(pid) do
    try do
      GenServer.call(pid, :snapshot)
    catch
      :exit, _reason -> nil
    end
  end

  defp open(matches) do
    matches
    |> Enum.flat_map(fn {id, entry} ->
      case entry.snapshot do
        %{visibility: :public, phase: phase, players: players}
        when phase in [:waiting, :countdown] and length(players) < 8 ->
          if Process.alive?(entry.pid),
            do: [%{id: id, player_count: length(players), capacity: 8}],
            else: []

        _ ->
          []
      end
    end)
    |> Enum.sort_by(& &1.id)
  end

  defp publish(matches) do
    Phoenix.PubSub.broadcast(Arena.PubSub, @topic, {:lobby_updated, open(matches)})
  end
end
