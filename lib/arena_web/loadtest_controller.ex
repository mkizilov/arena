defmodule ArenaWeb.LoadtestController do
  @moduledoc false
  use Phoenix.Controller, formats: [:json]

  def measurements(conn, _params) do
    {bytes, count} =
      Arena.MatchSupervisor
      |> Horde.DynamicSupervisor.which_children()
      |> Enum.reduce({0, 0}, fn
        {_, pid, _, _}, {bytes, count} when is_pid(pid) and node(pid) == node() ->
          case Process.info(pid, :memory) do
            {:memory, size} -> {bytes + size, count + 1}
            nil -> {bytes, count}
          end

        _, acc ->
          acc
      end)

    {runtime_ms, _} = :erlang.statistics(:runtime)
    metrics = Arena.Observability.snapshot()

    json(conn, %{
      build_env: Application.fetch_env!(:arena, :build_env),
      timestamp_ms: System.system_time(:millisecond),
      runtime_ms: runtime_ms,
      vm_memory_bytes: :erlang.memory(:total),
      match_process_memory_bytes: bytes,
      match_process_count: count,
      promex_pid:
        case Process.whereis(Arena.PromEx) do
          nil -> nil
          pid -> pid |> :erlang.pid_to_list() |> List.to_string()
        end,
      metrics_generation: metrics.generation,
      overruns: metrics.overruns,
      messages_in: metrics.messages_in,
      messages_out: metrics.messages_out,
      os_pid: System.pid()
    })
  end
end
