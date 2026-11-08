defmodule Arena.MatchStore do
  @moduledoc "Owns local checkpoints and synchronously replicates them to another node."
  use GenServer
  require Logger

  alias Arena.MatchReplica

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  def get(id), do: GenServer.call(__MODULE__, {:get, id})
  def get(id, instance), do: GenServer.call(__MODULE__, {:get, id, instance}, 10_000)
  def prepare(id, instance), do: GenServer.call(__MODULE__, {:prepare, id, instance}, 10_000)
  def abort_prepare(id, instance), do: GenServer.call(__MODULE__, {:abort_prepare, id, instance}, 10_000)
  def put(id, state), do: GenServer.call(__MODULE__, {:put, id, state}, 10_000)
  def delete(id), do: GenServer.call(__MODULE__, {:delete, id}, 10_000)
  def finish(id, state, result), do: GenServer.call(__MODULE__, {:finish, id, state, result}, 10_000)
  def pending_results, do: GenServer.call(__MODULE__, :pending_results)
  def complete_result(id), do: GenServer.call(__MODULE__, {:complete_result, id})
  def states, do: GenServer.call(__MODULE__, :states)

  @impl true
  def init(:ok) do
    :net_kernel.monitor_nodes(true)
    Process.send_after(self(), :sync_loop, 5_000)
    {:ok, :ets.new(__MODULE__, [:set, :private])}
  end

  @impl true
  def handle_call({:get, id}, _from, table) do
    result = case :ets.lookup(table, id) do
      [{^id, state}] -> {:ok, state}
      [] -> :error
    end
    {:reply, result, table}
  end

  def handle_call({:prepare, id, instance}, _from, table) do
    envelope = %{seq: 0, state: nil, result: nil}
    case replicate(id, instance, envelope) do
      :ok ->
        :ets.insert(table, {{:prepared, id, instance}, envelope})
        {:reply, :ok, table}
      error -> {:reply, error, table}
    end
  end

  def handle_call({:abort_prepare, id, instance}, _from, table) do
    :ets.delete(table, {:prepared, id, instance})
    delete_replicas(id, instance)
    {:reply, :ok, table}
  end

  def handle_call({:get, id, instance}, _from, table) do
    replicas = replica_candidates(id, instance)
    candidates = local_candidates(table, id, instance) ++ Enum.filter(replicas, &is_map/1)
    result = if :deleted in replicas, do: :deleted, else: Enum.max_by(candidates, & &1.seq, fn -> nil end)

    case result do
      nil -> {:reply, :error, table}
      :deleted -> {:reply, :deleted, table}
      %{state: nil} ->
        :ets.insert(table, {{:version, id, instance}, 0})
        {:reply, :new, table}
      envelope ->
        :ets.insert(table, [{id, envelope.state}, {{:version, id, instance}, envelope.seq}])
        if envelope.result do
          :ets.insert_new(table, {{:result, envelope.result.result_id}, envelope.result})
          Arena.ResultWriter.wake()
        end
        {:reply, {:ok, envelope.state}, table}
    end
  end

  def handle_call({:put, id, state}, _from, table) do
    persist(table, id, state, nil)
  end

  def handle_call({:finish, id, state, result}, _from, table) do
    persist(table, id, state, result)
  end

  def handle_call({:delete, id}, _from, table) do
    case :ets.lookup(table, id) do
      [{^id, state}] ->
        :ets.delete(table, {:version, id, state.result_id})
        :ets.delete(table, {:prepared, id, state.result_id})
        delete_replicas(id, state.result_id)
        Enum.each(Node.list(), fn target -> GenServer.cast({__MODULE__, target}, {:forget, id, state.result_id}) end)
      [] -> :ok
    end
    :ets.delete(table, id)
    {:reply, :ok, table}
  end

  def handle_call(:pending_results, _from, table) do
    results = for {{:result, id}, result} <- :ets.match_object(table, {{:result, :_}, :_}), do: {id, result}
    {:reply, results, table}
  end

  def handle_call(:states, _from, table) do
    states = for {id, state} <- :ets.tab2list(table), is_binary(id), do: {id, state}
    {:reply, states, table}
  end

  def handle_call({:complete_result, id}, _from, table) do
    :ets.delete(table, {:result, id})
    {:reply, :ok, table}
  end

  @impl true
  def handle_cast({:forget, id, instance}, table) do
    case :ets.lookup(table, id) do
      [{^id, %{result_id: ^instance}}] -> :ets.delete(table, id)
      _ -> :ok
    end
    :ets.delete(table, {:version, id, instance})
    :ets.delete(table, {:prepared, id, instance})
    {:noreply, table}
  end

  @impl true
  def handle_info({:nodeup, _node}, table) do
    Process.send_after(self(), :sync_once, 500)
    {:noreply, table}
  end

  def handle_info(:sync_loop, table) do
    Process.send_after(self(), :sync_loop, 5_000)
    start_sync(table)
    {:noreply, table}
  end

  def handle_info(:sync_once, table) do
    start_sync(table)
    {:noreply, table}
  end

  def handle_info({:nodedown, _node}, table), do: {:noreply, table}

  def handle_info({:sync_failed, id, instance, reason}, table) do
    case :ets.lookup(table, id) do
      [{^id, %{result_id: ^instance}}] -> Logger.warning("replica synchronization failed: #{inspect(reason)}", match_id: id)
      _ -> :ok
    end
    {:noreply, table}
  end

  defp start_sync(table) do
    running = case :ets.lookup(table, :sync_task) do
      [{:sync_task, pid}] -> Process.alive?(pid)
      [] -> false
    end

    if not running and Node.list() != [] and Process.whereis(Arena.TaskSupervisor) do
      snapshots = for {id, state} <- :ets.tab2list(table), is_binary(id),
        do: {id, state.result_id, envelope(table, id, state)}

      owner = self()
      case Task.Supervisor.start_child(Arena.TaskSupervisor, fn ->
        Enum.each(snapshots, fn {id, instance, value} ->
          if locally_owned?(id) do
            case replicate(id, instance, value) do
              :ok -> :ok
              error -> send(owner, {:sync_failed, id, instance, error})
            end
          end
        end)
      end) do
        {:ok, pid} -> :ets.insert(table, {:sync_task, pid})
        {:error, reason} -> Logger.warning("replica resync could not start: #{inspect(reason)}")
      end
    end
    :ok
  end

  defp persist(table, id, state, result) do
    instance = state.result_id
    seq = version(table, id, instance) + 1
    pending = result || case :ets.lookup(table, {:result, instance}) do
      [{_, existing}] -> existing
      [] -> nil
    end
    value = %{seq: seq, state: state, result: pending}

    case replicate(id, instance, value) do
      :ok ->
        objects = [{id, state}, {{:version, id, instance}, seq}]
        objects = if result, do: [{{:result, result.result_id}, result} | objects], else: objects
        true = :ets.insert(table, objects)
        {:reply, :ok, table}

      error -> {:reply, error, table}
    end
  end

  defp local_candidates(table, id, instance) do
    state = case :ets.lookup(table, id) do
      [{^id, %{result_id: ^instance} = saved}] -> [envelope(table, id, saved)]
      _ -> []
    end
    prepared = case :ets.lookup(table, {:prepared, id, instance}) do
      [{_, value}] -> [value]
      [] -> []
    end
    state ++ prepared
  end

  defp replica_candidates(id, instance) do
    [node() | Node.list()]
    |> Enum.flat_map(fn target ->
      case replica_call(fn -> MatchReplica.get(target, id, instance) end) do
        {:ok, value} -> [value]
        :deleted -> [:deleted]
        _ -> []
      end
    end)
  end

  defp envelope(table, id, state) do
    result = case :ets.lookup(table, {:result, state.result_id}) do
      [{_, value}] -> value
      [] -> nil
    end
    %{seq: version(table, id, state.result_id), state: state, result: result}
  end

  defp version(table, id, instance) do
    case :ets.lookup(table, {:version, id, instance}) do
      [{_, seq}] -> seq
      [] -> 0
    end
  end

  defp replicate(id, instance, value) do
    case Node.list() |> Enum.sort() do
      [] -> :ok
      peers ->
        if Enum.any?(peers, fn target -> replica_call(fn -> MatchReplica.put(target, id, instance, value) end) == :ok end),
          do: :ok, else: {:error, :replica_unavailable}
    end
  end

  defp delete_replicas(id, instance) do
    Enum.each([node() | Node.list()], fn target ->
      case replica_call(fn -> MatchReplica.delete(target, id, instance) end) do
        :ok -> :ok
        _ -> Logger.warning("unable to delete replica", match_id: id)
      end
    end)
  end

  defp replica_call(fun) do
    try do
      fun.()
    catch
      :exit, _ -> :error
    end
  end

  defp locally_owned?(id) do
    case Horde.Registry.lookup(Arena.MatchRegistry, id) do
      [{pid, _}] -> node(pid) == node()
      _ -> false
    end
  end
end
