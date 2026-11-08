defmodule ArenaLoad.Prometheus do
  @moduledoc "Parses the server's unlabelled Prometheus counters and cumulative tick histogram."

  @line ~r/^(?<name>[a-zA-Z_:][a-zA-Z0-9_:]*)(?:\{(?<labels>[^}]*)\})?\s+(?<value>[+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?)/
  @bucket "arena_match_tick_duration_us_bucket"
  @counters %{
    overruns: "arena_match_overrun_count",
    messages_in: "arena_channel_in_messages",
    messages_out: "arena_channel_out_messages"
  }

  def parse(text) do
    Enum.reduce(String.split(text, "\n"), %{buckets: %{}, overruns: nil, messages_in: nil, messages_out: nil}, fn line, acc ->
      case Regex.named_captures(@line, line) do
        %{"name" => @bucket, "labels" => labels, "value" => value} ->
          case Regex.run(~r/(?:^|,)le="([^"]+)"/, labels) do
            [_, bound] -> put_in(acc, [:buckets, bound], number(value))
            _ -> acc
          end

        %{"name" => name, "value" => value} ->
          case Enum.find(@counters, fn {_key, prefix} -> name in [prefix, prefix <> "_total"] end) do
            {key, _} -> Map.put(acc, key, number(value))
            nil -> acc
          end

        _ -> acc
      end
    end)
  end

  def difference(before, after_sample, seconds) do
    buckets = Map.new(after_sample.buckets, fn {bound, value} ->
      {bound, value - Map.get(before.buckets, bound, 0.0)}
    end)

    valid = Map.has_key?(buckets, "+Inf") and Enum.all?(buckets, fn {_, value} -> value >= 0 end)

    %{
      tick_samples: if(valid, do: buckets["+Inf"], else: nil),
      tick_p50_us_upper_bound: if(valid, do: percentile(buckets, 0.50), else: nil),
      tick_p99_us_upper_bound: if(valid, do: percentile(buckets, 0.99), else: nil),
      overruns: subtract(before.overruns, after_sample.overruns),
      messages_in_per_second: rate(before.messages_in, after_sample.messages_in, seconds),
      messages_out_per_second: rate(before.messages_out, after_sample.messages_out, seconds),
      histogram_error: if(valid, do: nil, else: "missing or reset tick histogram")
    }
  end

  defp percentile(buckets, quantile) do
    total = buckets["+Inf"]
    if total <= 0 do
      nil
    else
      buckets
      |> Enum.map(fn
        {"+Inf", value} -> {:infinity, value}
        {bound, value} -> {number(bound), value}
      end)
      |> Enum.sort_by(fn
        {:infinity, _} -> {1, 0}
        {bound, _} -> {0, bound}
      end)
      |> Enum.find(fn {_bound, value} -> value >= total * quantile end)
      |> case do
        {:infinity, _} -> "+Inf"
        {bound, _} -> bound
        nil -> nil
      end
    end
  end

  defp subtract(_, nil), do: nil
  defp subtract(nil, value), do: value
  defp subtract(before, value) when value >= before, do: value - before
  defp subtract(_, _), do: nil
  defp rate(before, value, seconds) do
    case subtract(before, value) do
      nil -> nil
      difference -> difference / seconds
    end
  end

  defp number(value), do: elem(Float.parse(value), 0)
end
