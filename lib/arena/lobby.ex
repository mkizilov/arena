defmodule Arena.Lobby do
  @moduledoc "Tracks supervised matches and publishes the public lobby."
  use GenServer

  alias Arena.Match

  @topic "lobby"

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @doc "Starts and tracks a match. Use `Arena.Match.start_match/2` as the public entry point."
  def start_match(id, opts), do: GenServer.call(__MODULE__, {:start_match, id, opts}, 30_000)

  @doc "Returns the sorted IDs of currently live matches."
  def matches, do: GenServer.call(__MODULE__, :matches)

  @doc "Returns public waiting or countdown matches with available capacity."
  def open_matches, do: GenServer.call(__MODULE__, :open_matches)

  @doc "Returns the PubSub topic for lobby snapshots."
  def topic, do: @topic

  @impl true
  def init(:ok) do
    :ok = Phoenix.PubSub.subscribe(Arena.PubSub, "arena:matches")
    Process.send_after(self(), :reconcile, 5_000)
    matches = discover(%{})
    publish(matches)
    {:ok, matches}
  end

  defp discover(matches) do
    Arena.MatchSupervisor
    |> Horde.DynamicSupervisor.which_children()
    |> Enum.reduce(matches, &discover_child/2)
  end

  defp discover_child({_, pid, _, _}, matches) when is_pid(pid) do
    case Horde.Registry.keys(Arena.MatchRegistry, pid) do
      [id] -> track_discovered(matches, id, pid)
      [] -> matches
    end
  end

  defp discover_child(_, matches), do: matches

  defp track_discovered(matches, id, pid) do
    case Map.get(matches, id) do
      %{pid: ^pid} ->
        matches

      existing ->
        if existing, do: Process.demonitor(existing.ref, [:flush])
        if is_nil(existing), do: Phoenix.PubSub.subscribe(Arena.PubSub, Match.topic(id))
        Map.put(matches, id, track(pid))
    end
  end

  @impl true
  def handle_call(:matches, _from, matches) do
    ids =
      matches
      |> Enum.filter(fn {_, entry} -> Arena.Cluster.alive?(entry.pid) end)
      |> Enum.map(&elem(&1, 0))
      |> Enum.sort()

    {:reply, ids, matches}
  end

  def handle_call(:open_matches, _from, matches), do: {:reply, open(matches), matches}

  def handle_call({:start_match, id, opts}, _from, matches) do
    case Map.fetch(matches, id) do
      {:ok, entry} ->
        {:reply, {:error, {:already_started, entry.pid}}, matches}

      :error ->
        start_new_match(id, opts, matches)
    end
  end

  defp start_new_match(id, opts, matches) do
    :ok = Phoenix.PubSub.subscribe(Arena.PubSub, Match.topic(id))

    result =
      case Horde.Registry.lookup(Arena.MatchRegistry, id) do
        [{pid, _}] ->
          {:error, {:already_started, pid}}

        [] ->
          with :ok <- Arena.MatchStore.prepare(id, Keyword.fetch!(opts, :instance_id)) do
            Horde.DynamicSupervisor.start_child(Arena.MatchSupervisor, {Match, {id, opts}})
          end
      end

    case result do
      {:ok, pid} ->
        matches = Map.put(matches, id, track(pid))
        publish(matches)
        {:reply, {:ok, pid}, matches}

      error ->
        Arena.MatchStore.abort_prepare(id, Keyword.fetch!(opts, :instance_id))
        Phoenix.PubSub.unsubscribe(Arena.PubSub, Match.topic(id))
        {:reply, error, matches}
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

  def handle_info(%Phoenix.Socket.Broadcast{event: event}, matches)
      when event in ["delta", "state"],
      do: {:noreply, matches}

  def handle_info({:match_ended_unexpectedly, _id}, matches), do: {:noreply, matches}
  def handle_info({:match_recovering, _id}, matches), do: {:noreply, matches}
  def handle_info({:match_disconnected, _id, _player}, matches), do: {:noreply, matches}
  def handle_info({:match_reconnected, _id, _player}, matches), do: {:noreply, matches}

  def handle_info({:match_registered, id, pid, kind}, matches) do
    case Map.get(matches, id) do
      %{pid: ^pid} ->
        announce_recovery(kind, id, pid, true)

        {:noreply, matches}

      existing ->
        if existing, do: Process.demonitor(existing.ref, [:flush])
        if is_nil(existing), do: Phoenix.PubSub.subscribe(Arena.PubSub, Match.topic(id))
        matches = Map.put(matches, id, track(pid))
        publish(matches)

        announce_recovery(kind, id, pid, is_nil(existing) or not existing.recovering)

        {:noreply, matches}
    end
  end

  def handle_info({:match_recovered, _id, _pid}, matches), do: {:noreply, matches}

  def handle_info(:reconcile, matches) do
    Process.send_after(self(), :reconcile, 5_000)
    updated = discover(matches)
    if updated != matches, do: publish(updated)
    {:noreply, updated}
  end

  def handle_info({:DOWN, ref, :process, pid, reason}, matches) do
    case Enum.find(matches, fn {_id, entry} -> entry.pid == pid and entry.ref == ref end) do
      {id, _} ->
        if reason not in [:normal, :shutdown] and not match?({:shutdown, _}, reason) do
          Phoenix.PubSub.broadcast(Arena.PubSub, Match.topic(id), {:match_recovering, id})
          Process.send_after(self(), {:recovery_timeout, id, ref}, 15_000)
          matches = update_in(matches[id], &%{&1 | recovering: true})
          publish(matches)
          {:noreply, matches}
        else
          Phoenix.PubSub.unsubscribe(Arena.PubSub, Match.topic(id))
          matches = Map.delete(matches, id)
          publish(matches)
          {:noreply, matches}
        end

      nil ->
        {:noreply, matches}
    end
  end

  def handle_info({:recovery_timeout, id, ref}, matches) do
    case Map.fetch(matches, id) do
      {:ok, %{ref: ^ref, pid: pid}} ->
        if Arena.Cluster.alive?(pid) do
          {:noreply, matches}
        else
          Phoenix.PubSub.broadcast(Arena.PubSub, Match.topic(id), {:match_ended_unexpectedly, id})
          Arena.Observability.remove(id)
          Phoenix.PubSub.unsubscribe(Arena.PubSub, Match.topic(id))
          matches = Map.delete(matches, id)
          publish(matches)
          {:noreply, matches}
        end

      _ ->
        {:noreply, matches}
    end
  end

  defp announce_recovery(:recovered, id, pid, notify) when node(pid) == node() do
    if notify,
      do: Phoenix.PubSub.broadcast(Arena.PubSub, Match.topic(id), {:match_recovering, id})

    Phoenix.PubSub.broadcast(Arena.PubSub, Match.topic(id), {:match_recovered, id, pid})
  end

  defp announce_recovery(_, _, _, _), do: :ok

  defp track(pid),
    do: %{pid: pid, ref: Process.monitor(pid), snapshot: snapshot(pid), recovering: false}

  defp snapshot(pid) do
    GenServer.call(pid, :snapshot)
  catch
    :exit, _reason -> nil
  end

  defp open(matches) do
    matches
    |> Enum.flat_map(&open_entry/1)
    |> Enum.sort_by(& &1.id)
  end

  defp open_entry(
         {id, %{snapshot: %{visibility: :public, phase: phase, players: players}} = entry}
       )
       when phase in [:waiting, :countdown] and length(players) < 8 do
    if Arena.Cluster.alive?(entry.pid),
      do: [%{id: id, player_count: length(players), capacity: 8}],
      else: []
  end

  defp open_entry(_), do: []

  defp publish(matches) do
    Phoenix.PubSub.broadcast(Arena.PubSub, @topic, {:lobby_updated, open(matches)})
  end
end
