defmodule ArenaLoad.Runner do
  @moduledoc "Runs bounded loopback-only bot loads and prints a JSON measurement report."

  alias ArenaLoad.{Bot, HTTP, Prometheus, Stats}

  def run(opts) do
    port = Keyword.fetch!(opts, :port)
    stats = Stats.new()

    try do
      server = get_json!(port, "/loadtest/measurements")
      if server["build_env"] != "prod", do: raise("server must run a production build")
      pid = server["os_pid"]
      unless is_binary(pid) and Regex.match?(~r/\A[1-9][0-9]*\z/, pid), do: raise("invalid server process ID")

      started = start_bots(opts, stats)
      Process.sleep(opts[:warmup] * 1_000)
      before = get_json!(port, "/loadtest/measurements")
      if before["promex_pid"] == nil, do: raise("PromEx is not running")
      metrics_before = get_metrics!(port)
      bots_before = Stats.snapshot(stats)
      start_time = System.monotonic_time(:millisecond)
      cpu_samples = sample_cpu(pid, opts[:duration])
      elapsed_ms = max(System.monotonic_time(:millisecond) - start_time, 1)
      bots_after = Stats.snapshot(stats)
      metrics_after = get_metrics!(port)
      after_sample = get_json!(port, "/loadtest/measurements")
      if after_sample["os_pid"] != pid, do: raise("server process changed during measurement")
      if after_sample["metrics_generation"] != before["metrics_generation"], do: raise("observability process restarted during measurement")
      if after_sample["promex_pid"] != before["promex_pid"], do: raise("PromEx restarted during measurement")

      seconds = elapsed_ms / 1_000
      bot_delta = Stats.difference(bots_before, bots_after)
      server_metrics = Prometheus.difference(metrics_before, metrics_after, seconds)
      server_metrics = Map.merge(server_metrics, %{
        overruns: delta(before["overruns"], after_sample["overruns"]),
        messages_in_per_second: rate(before["messages_in"], after_sample["messages_in"], seconds),
        messages_out_per_second: rate(before["messages_out"], after_sample["messages_out"], seconds)
      })
      match_count = after_sample["match_process_count"]
      memory = after_sample["match_process_memory_bytes"]
      valid_run = started == opts[:bots] and bots_before.online == opts[:bots] and
        bots_after.online == opts[:bots] and bots_before.matched_bots == opts[:bots] and bot_delta.ticks > 0 and
        is_number(server_metrics.tick_samples) and server_metrics.tick_samples > 0 and
        is_number(server_metrics.overruns) and is_number(server_metrics.messages_in_per_second) and
        is_number(server_metrics.messages_out_per_second) and match_count > 0 and memory > 0 and
        cpu_samples != [] and bot_delta.invalid_latency == 0 and
        is_number(after_sample["runtime_ms"]) and after_sample["runtime_ms"] >= before["runtime_ms"]

      report = %{
        requested_bots: opts[:bots], started_bots: started, valid_run: valid_run,
        online_before: bots_before.online, online_after: bots_after.online,
        matched_bots_before: bots_before.matched_bots,
        duration_seconds: seconds,
        bot_tick_arrivals_per_second: bot_delta.ticks / seconds,
        bot_inputs_per_second: bot_delta.inputs / seconds,
        bot_latency_p50_ms_upper_bound: Stats.percentile(bot_delta.latency_buckets, 0.50),
        bot_latency_p99_ms_upper_bound: Stats.percentile(bot_delta.latency_buckets, 0.99),
        invalid_clock_samples: bot_delta.invalid_latency,
        bot_disconnects: bot_delta.disconnects, bot_errors: bot_delta.errors,
        match_joins: bot_delta.match_joins,
        server: server_metrics,
        server_vm_memory_bytes: after_sample["vm_memory_bytes"],
        match_process_count: match_count,
        mean_match_process_memory_bytes: if(match_count > 0, do: memory / match_count, else: nil),
        beam_runtime_percent_one_core: (after_sample["runtime_ms"] - before["runtime_ms"]) / elapsed_ms * 100,
        os_cpu_percent_mean: mean(cpu_samples),
        os_cpu_samples: length(cpu_samples),
        os_cpu_error: if(cpu_samples == [], do: "ps unavailable or no parseable samples", else: nil)
      }

      IO.puts(Jason.encode!(report, pretty: true))
      if not valid_run, do: raise("incomplete run: inspect counts and missing/reset metrics in the report")
      report
    after
      stop_bots()
    end
  end

  defp start_bots(opts, stats) do
    {started, _failures} = Enum.reduce_while(1..opts[:bots], {0, 0}, fn number, {started, failures} ->
      result = with {:ok, %{"id" => player, "token" => token}} <- HTTP.json(opts[:port], "/guest") do
        DynamicSupervisor.start_child(ArenaLoad.BotSupervisor, {Bot, [number: number, player: player, token: token, port: opts[:port], stats: stats]})
      end

      {started, failures} = case result do
        {:ok, _pid} -> {started + 1, 0}
        _ -> Stats.add(stats, :errors); {started, failures + 1}
      end

      if opts[:ramp_ms] > 0, do: Process.sleep(opts[:ramp_ms])
      if failures >= 10, do: {:halt, {started, failures}}, else: {:cont, {started, failures}}
    end)

    started
  end

  defp get_json!(port, path) do
    case HTTP.json(port, path) do
      {:ok, body} -> body
      {:error, reason} -> raise "#{path} failed: #{inspect(reason)}"
    end
  end

  defp get_metrics!(port) do
    case HTTP.get(port, "/metrics") do
      {:ok, body} -> Prometheus.parse(body)
      {:error, reason} -> raise "/metrics failed: #{inspect(reason)}"
    end
  end

  defp sample_cpu(pid, seconds) do
    Enum.reduce(1..seconds, [], fn _, samples ->
      Process.sleep(1_000)
      case cpu_sample(pid) do
        {output, 0} ->
          case Float.parse(String.trim(output)) do
            {value, _} -> [value | samples]
            :error -> samples
          end
        _ -> samples
      end
    end)
  end

  defp cpu_sample(pid) do
    System.cmd("ps", ["-p", pid, "-o", "%cpu="], stderr_to_stdout: true)
  rescue
    error in ErlangError -> {Exception.message(error), 1}
  end

  defp mean([]), do: nil
  defp mean(samples), do: Enum.sum(samples) / length(samples)

  defp delta(before, after_sample) when is_number(before) and is_number(after_sample) and after_sample >= before,
    do: after_sample - before
  defp delta(_, _), do: nil

  defp rate(before, after_sample, seconds) do
    case delta(before, after_sample) do
      nil -> nil
      value -> value / seconds
    end
  end

  defp stop_bots do
    ArenaLoad.BotSupervisor
    |> DynamicSupervisor.which_children()
    |> Enum.each(fn
      {_, pid, _, _} when is_pid(pid) -> DynamicSupervisor.terminate_child(ArenaLoad.BotSupervisor, pid)
      _ -> :ok
    end)
  end
end
