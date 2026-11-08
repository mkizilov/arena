defmodule Arena.MatchStore do
  @moduledoc "Owns the node-local ETS table of match checkpoints."
  use GenServer

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  def get(id), do: GenServer.call(__MODULE__, {:get, id})
  def put(id, state), do: GenServer.call(__MODULE__, {:put, id, state})
  def delete(id), do: GenServer.call(__MODULE__, {:delete, id})
  def finish(id, state, result), do: GenServer.call(__MODULE__, {:finish, id, state, result})
  def pending_results, do: GenServer.call(__MODULE__, :pending_results)
  def complete_result(id), do: GenServer.call(__MODULE__, {:complete_result, id})
  def states, do: GenServer.call(__MODULE__, :states)

  @impl true
  def init(:ok), do: {:ok, :ets.new(__MODULE__, [:set, :private])}

  @impl true
  def handle_call({:get, id}, _from, table) do
    result = case :ets.lookup(table, id) do
      [{^id, state}] -> {:ok, state}
      [] -> :error
    end

    {:reply, result, table}
  end

  def handle_call({:put, id, state}, _from, table) do
    true = :ets.insert(table, {id, state})
    {:reply, :ok, table}
  end

  def handle_call({:delete, id}, _from, table) do
    true = :ets.delete(table, id)
    {:reply, :ok, table}
  end

  def handle_call({:finish, id, state, result}, _from, table) do
    true = :ets.insert(table, [{id, state}, {{:result, result.result_id}, result}])
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
    true = :ets.delete(table, {:result, id})
    {:reply, :ok, table}
  end
end
