defmodule Arena.MatchReplica do
  @moduledoc "Owns node-local copies of other nodes' match checkpoints."
  use GenServer

  @ttl_ms 30 * 60 * 1_000
  @sweep_ms 60_000

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  def put(target, id, instance, envelope), do: GenServer.call(server(target), {:put, id, instance, envelope}, 1_000)
  def get(target, id, instance), do: GenServer.call(server(target), {:get, id, instance}, 1_000)
  def delete(target, id, instance), do: GenServer.call(server(target), {:delete, id, instance}, 1_000)

  defp server(target) when target == node(), do: __MODULE__
  defp server(target), do: {__MODULE__, target}

  @impl true
  def init(:ok) do
    table = :ets.new(__MODULE__, [:set, :private])
    Process.send_after(self(), :sweep, @sweep_ms)
    {:ok, table}
  end

  @impl true
  def handle_call({:put, id, instance, envelope}, _from, table) do
    key = {id, instance}
    result = case :ets.lookup(table, key) do
      [{^key, %{deleted: true}, _}] ->
        :ets.insert(table, {key, %{deleted: true}, System.monotonic_time(:millisecond)})
        {:error, :deleted}
      [{^key, existing, _}] when existing.seq > envelope.seq -> {:error, :stale}
      _ ->
        :ets.insert(table, {key, envelope, System.monotonic_time(:millisecond)})
        :ok
    end
    {:reply, result, table}
  end

  def handle_call({:get, id, instance}, _from, table) do
    result = case :ets.lookup(table, {id, instance}) do
      [{_, %{deleted: true}, _}] -> :deleted
      [{_, envelope, _}] -> {:ok, envelope}
      [] -> :error
    end
    {:reply, result, table}
  end

  def handle_call({:delete, id, instance}, _from, table) do
    :ets.insert(table, {{id, instance}, %{deleted: true}, System.monotonic_time(:millisecond)})
    {:reply, :ok, table}
  end

  @impl true
  def handle_info(:sweep, table) do
    cutoff = System.monotonic_time(:millisecond) - @ttl_ms
    :ets.select_delete(table, [{{:_, :_, :'$1'}, [{:<, :'$1', cutoff}], [true]}])
    Process.send_after(self(), :sweep, @sweep_ms)
    {:noreply, table}
  end
end
