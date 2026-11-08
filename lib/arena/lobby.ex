defmodule Arena.Lobby do
  @moduledoc "Tracks supervised matches and reports abnormal termination to their subscribers."
  use GenServer

  alias Arena.Match

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @doc "Starts and tracks a match. Use `Arena.Match.start_match/2` as the public entry point."
  def start_match(id, opts), do: GenServer.call(__MODULE__, {:start_match, id, opts})

  @doc "Returns the sorted IDs of currently live matches."
  def matches, do: GenServer.call(__MODULE__, :matches)

  @impl true
  def init(:ok) do
    matches =
      Arena.MatchSupervisor
      |> DynamicSupervisor.which_children()
      |> Enum.reduce(%{}, fn
        {_, pid, _, _}, matches when is_pid(pid) ->
          case Registry.keys(Arena.MatchRegistry, pid) do
            [id] -> Map.put(matches, id, {pid, Process.monitor(pid)})
            [] -> matches
          end

        _, matches ->
          matches
      end)

    {:ok, matches}
  end

  @impl true
  def handle_call(:matches, _from, matches) do
    ids =
      matches
      |> Enum.filter(fn {_id, {pid, _ref}} -> Process.alive?(pid) end)
      |> Enum.map(&elem(&1, 0))
      |> Enum.sort()

    {:reply, ids, matches}
  end

  def handle_call({:start_match, id, opts}, _from, matches) do
    case Map.fetch(matches, id) do
      {:ok, {pid, _ref}} ->
        {:reply, {:error, {:already_started, pid}}, matches}

      :error ->
        case DynamicSupervisor.start_child(Arena.MatchSupervisor, {Match, {id, opts}}) do
          {:ok, pid} ->
            {:reply, {:ok, pid}, Map.put(matches, id, {pid, Process.monitor(pid)})}

          error ->
            {:reply, error, matches}
        end
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, pid, reason}, matches) do
    case Enum.find(matches, fn {_id, entry} -> entry == {pid, ref} end) do
      {id, _} ->
        if reason not in [:normal, :shutdown] and not match?({:shutdown, _}, reason) do
          Phoenix.PubSub.broadcast(Arena.PubSub, Match.topic(id), {:match_ended_unexpectedly, id})
        end

        {:noreply, Map.delete(matches, id)}

      nil ->
        {:noreply, matches}
    end
  end
end
