defmodule Arena.MatchStore do
  @moduledoc "Owns the node-local ETS table of match checkpoints."
  use GenServer

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  def get(id), do: GenServer.call(__MODULE__, {:get, id})
  def put(id, state), do: GenServer.call(__MODULE__, {:put, id, state})
  def delete(id), do: GenServer.call(__MODULE__, {:delete, id})

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
end
