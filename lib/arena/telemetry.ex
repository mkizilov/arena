defmodule Arena.Telemetry do
  @moduledoc "Telemetry events emitted by the match and transport boundaries."
  require Logger

  def tick(match_id, tick, duration_ns) do
    measurements = %{duration_ns: duration_ns, duration_us: div(duration_ns, 1_000), tick: tick}
    :telemetry.execute([:arena, :match, :tick], measurements, %{match_id: match_id})

    if duration_ns * 15 > 1_000_000_000 do
      :telemetry.execute([:arena, :match, :overrun], %{count: 1, duration_ns: duration_ns}, %{match_id: match_id})
      Logger.warning("match #{inspect(match_id)} tick overrun: #{measurements.duration_us}µs", match_id: match_id)
    end
  end

  def channel(direction, event, match_id, player_id, count \\ 1) do
    :telemetry.execute(
      [:arena, :channel, :message],
      %{count: count},
      %{direction: direction, event: event, match_id: match_id, player_id: player_id}
    )
  end

  def matchmaking(match_id, player_id, wait_ms) do
    :telemetry.execute([:arena, :matchmaking, :wait], %{wait_ms: wait_ms}, %{match_id: match_id, player_id: player_id})
  end
end
