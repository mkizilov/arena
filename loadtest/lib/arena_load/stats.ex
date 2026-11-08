defmodule ArenaLoad.Stats do
  @moduledoc "Bounded, concurrent counters and latency buckets for the load generator."

  @bounds [1, 2, 5, 10, 20, 50, 100, 200, 500, 1_000, 2_000, 5_000, 10_000, 30_000]
  @indices %{connected: 1, lobby_joins: 2, match_joins: 3, ticks: 4, inputs: 5, disconnects: 6, errors: 7, invalid_latency: 8, online: 9, matched_bots: 10}
  @offset 11

  def new, do: :counters.new(@offset + length(@bounds) + 1, [:write_concurrency])
  def add(ref, key, amount \\ 1), do: :counters.add(ref, Map.fetch!(@indices, key), amount)

  def latency(ref, milliseconds) when is_integer(milliseconds) and milliseconds >= 0 do
    position = Enum.find_index(@bounds, &(milliseconds <= &1)) || length(@bounds)
    :counters.add(ref, @offset + position, 1)
  end

  def latency(ref, _), do: add(ref, :invalid_latency)

  def snapshot(ref) do
    counters = Map.new(@indices, fn {name, index} -> {name, :counters.get(ref, index)} end)
    buckets = for index <- 0..length(@bounds), do: :counters.get(ref, @offset + index)
    Map.put(counters, :latency_buckets, buckets)
  end

  def difference(before, after_sample) do
    Map.new(before, fn
      {:latency_buckets, buckets} ->
        {:latency_buckets, Enum.zip_with(after_sample.latency_buckets, buckets, &(&1 - &2))}
      {key, value} ->
        {key, Map.fetch!(after_sample, key) - value}
    end)
  end

  def percentile(buckets, quantile) do
    total = Enum.sum(buckets)

    if total == 0 do
      nil
    else
      rank = max(ceil(total * quantile), 1)
      bounds = @bounds ++ ["+Inf"]
      Enum.zip(bounds, buckets)
      |> Enum.reduce_while(0, fn {bound, count}, cumulative ->
        if cumulative + count >= rank, do: {:halt, {:value, bound}}, else: {:cont, cumulative + count}
      end)
      |> elem(1)
    end
  end
end
