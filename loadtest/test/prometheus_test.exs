defmodule ArenaLoad.PrometheusTest do
  use ExUnit.Case, async: true
  alias ArenaLoad.Prometheus

  test "uses histogram and counter differences rather than lifetime totals" do
    before = Prometheus.parse("""
    arena_match_tick_duration_us_bucket{le="1000"} 10
    arena_match_tick_duration_us_bucket{le="5000"} 20
    arena_match_tick_duration_us_bucket{le="+Inf"} 20
    arena_match_overrun_count_total 3
    arena_channel_in_messages_total 100
    arena_channel_out_messages_total 200
    """)

    after_sample = Prometheus.parse("""
    arena_match_tick_duration_us_bucket{le="1000"} 12
    arena_match_tick_duration_us_bucket{le="5000"} 25
    arena_match_tick_duration_us_bucket{le="+Inf"} 25
    arena_match_overrun_count_total 4
    arena_channel_in_messages_total 120
    arena_channel_out_messages_total 260
    """)

    result = Prometheus.difference(before, after_sample, 10)
    assert result.tick_samples == 5
    assert result.tick_p50_us_upper_bound == 5_000
    assert result.tick_p99_us_upper_bound == 5_000
    assert result.overruns == 1
    assert result.messages_in_per_second == 2
    assert result.messages_out_per_second == 6
  end

  test "reports missing or reset histograms rather than inventing zeroes" do
    before = Prometheus.parse("arena_match_tick_duration_us_bucket{le=\"+Inf\"} 20")
    after_sample = Prometheus.parse("arena_match_tick_duration_us_bucket{le=\"+Inf\"} 10")
    result = Prometheus.difference(before, after_sample, 1)
    assert result.tick_p99_us_upper_bound == nil
    assert result.histogram_error != nil
    assert result.messages_in_per_second == nil
  end
end
