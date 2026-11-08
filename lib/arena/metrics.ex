defmodule Arena.Metrics do
  @moduledoc "Low-cardinality metric definitions shared by PromEx and LiveDashboard."
  import Telemetry.Metrics

  def metrics do
    [
      distribution("arena.match.tick.duration_us",
        event_name: [:arena, :match, :tick], measurement: :duration_us,
        description: "Match tick duration in microseconds",
        reporter_options: [buckets: [1_000, 5_000, 16_000, 33_000, 66_667, 100_000, 250_000, 1_000_000]]),
      counter("arena.match.overrun.count",
        event_name: [:arena, :match, :overrun], measurement: :count,
        description: "Ticks exceeding the 15 Hz interval"),
      last_value("arena.active.matches", event_name: [:arena, :population], measurement: :matches),
      last_value("arena.active.players", event_name: [:arena, :population], measurement: :players),
      sum("arena.channel.in.messages",
        event_name: [:arena, :channel, :message], measurement: :count,
        keep: &incoming?/1, description: "Inbound application channel messages"),
      sum("arena.channel.out.messages",
        event_name: [:arena, :channel, :message], measurement: :count,
        keep: &outgoing?/1, description: "Outbound application channel messages and estimated fanout"),
      distribution("arena.matchmaking.wait_ms",
        event_name: [:arena, :matchmaking, :wait], measurement: :wait_ms,
        description: "Quick-play wait time in milliseconds",
        reporter_options: [buckets: [100, 500, 1_000, 5_000, 10_000, 20_000, 60_000]])
    ]
  end

  defp incoming?(metadata), do: metadata.direction == :in
  defp outgoing?(metadata), do: metadata.direction == :out
end
