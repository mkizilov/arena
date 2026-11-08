defmodule ArenaLoad.StatsTest do
  use ExUnit.Case, async: true
  alias ArenaLoad.Stats

  test "bounded counters report interval differences and latency percentiles" do
    stats = Stats.new()
    Stats.add(stats, :online)
    before = Stats.snapshot(stats)
    Stats.latency(stats, 1)
    Stats.latency(stats, 3)
    Stats.latency(stats, 200)
    Stats.latency(stats, -1)
    Stats.add(stats, :ticks, 4)
    result = Stats.difference(before, Stats.snapshot(stats))
    assert result.ticks == 4
    assert result.invalid_latency == 1
    assert result.online == 0
    assert Stats.percentile(result.latency_buckets, 0.5) == 5
    assert Stats.percentile(result.latency_buckets, 0.99) == 200
  end

  test "empty histograms have no percentile" do
    stats = Stats.new()
    assert Stats.percentile(Stats.snapshot(stats).latency_buckets, 0.5) == nil
  end

  test "seeded bot directions never immediately reverse" do
    opposites = %{"up" => "down", "down" => "up", "left" => "right", "right" => "left"}

    for current <- Map.keys(opposites) do
      Enum.reduce(1..100, :rand.seed_s(:exsss, {1, 2, 3}), fn _, rng ->
        {direction, rng} = ArenaLoad.Bot.next_direction(current, rng)
        refute direction == opposites[current]
        rng
      end)
    end
  end
end
