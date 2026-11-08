defmodule Arena.ResultWriter do
  @moduledoc "Retries pending result transactions without blocking match processes."
  use GenServer
  require Logger

  @max_tasks 2
  @max_delay 30_000

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  def wake, do: GenServer.cast(__MODULE__, :wake)

  @impl true
  def init(:ok) do
    send(self(), :drain)
    Process.send_after(self(), :poll, 5_000)
    {:ok, %{running: %{}, cooling: MapSet.new(), failures: %{}}}
  end

  @impl true
  def handle_cast(:wake, state) do
    send(self(), :drain)
    {:noreply, state}
  end

  @impl true
  def handle_info(:poll, state) do
    Process.send_after(self(), :poll, 5_000)
    send(self(), :drain)
    {:noreply, state}
  end

  def handle_info(:drain, state) do
    running_ids = MapSet.new(state.running, fn {_ref, job} -> job.id end)
    slots = max(@max_tasks - map_size(state.running), 0)

    jobs =
      Arena.MatchStore.pending_results()
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.reject(fn {id, _} ->
        MapSet.member?(running_ids, id) or MapSet.member?(state.cooling, id)
      end)
      |> Enum.take(slots)

    state = Enum.reduce(jobs, state, fn {id, result}, acc -> start_task(acc, id, result) end)
    {:noreply, state}
  end

  def handle_info({ref, result}, state) when is_reference(ref) do
    case Map.pop(state.running, ref) do
      {nil, _} ->
        {:noreply, state}

      {job, running} ->
        Process.demonitor(ref, [:flush])
        state = %{state | running: running}
        id = job.id

        state =
          case result do
            {:ok, outcome} when outcome in [:inserted, :duplicate] ->
              :ok =
                Phoenix.PubSub.broadcast(
                  Arena.PubSub,
                  "leaderboard",
                  {:leaderboard_updated, job.match_id}
                )

              :ok = Arena.MatchStore.complete_result(id)
              %{state | failures: Map.delete(state.failures, id)}

            {:error, reason} ->
              retry(state, id, job.match_id, reason)

            other ->
              retry(state, id, job.match_id, {:unexpected_result, other})
          end

        send(self(), :drain)
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case Map.pop(state.running, ref) do
      {nil, _} ->
        {:noreply, state}

      {job, running} ->
        state = retry(%{state | running: running}, job.id, job.match_id, reason)
        send(self(), :drain)
        {:noreply, state}
    end
  end

  def handle_info({:retry, id}, state) do
    send(self(), :drain)
    {:noreply, %{state | cooling: MapSet.delete(state.cooling, id)}}
  end

  defp start_task(state, id, result) do
    task =
      Task.Supervisor.async_nolink(Arena.TaskSupervisor, fn ->
        Logger.metadata(match_id: result.match_id)

        :telemetry.execute(
          [:arena, :result_writer, :start],
          %{system_time: System.system_time()},
          %{match_id: result.match_id, result_id: id}
        )

        try do
          Arena.Results.record(result)
        rescue
          error -> {:error, Exception.message(error)}
        catch
          kind, reason -> {:error, {kind, reason}}
        end
      end)

    %{state | running: Map.put(state.running, task.ref, %{id: id, match_id: result.match_id})}
  catch
    :exit, reason -> retry(state, id, result.match_id, reason)
  end

  defp retry(state, id, match_id, reason) do
    count = Map.get(state.failures, id, 0) + 1
    delay = min(1_000 * Integer.pow(2, min(count - 1, 5)), @max_delay)

    Logger.warning(
      "result persistence failed for #{inspect(id)}; retrying in #{delay}ms: #{inspect(reason)}",
      match_id: match_id
    )

    :telemetry.execute([:arena, :result_writer, :retry], %{delay_ms: delay}, %{
      match_id: match_id,
      result_id: id
    })

    Process.send_after(self(), {:retry, id}, delay)

    %{
      state
      | cooling: MapSet.put(state.cooling, id),
        failures: Map.put(state.failures, id, count)
    }
  end
end
