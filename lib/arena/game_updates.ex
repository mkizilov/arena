defmodule Arena.GameUpdates do
  @moduledoc "Publishes one transport update per tick using Phoenix's serializer fastlane."

  alias ArenaWeb.GameJSON
  alias Phoenix.Channel.Server

  def snapshot(id, game) do
    Server.broadcast(
      Arena.PubSub,
      Arena.Match.topic(id),
      "state",
      %{state: GameJSON.render(game), events: []}
    )
  end

  def publish(id, previous, game, events, tick_started_at_ms \\ nil) do
    event = event(game.tick)

    payload =
      if event == "state" do
        %{state: GameJSON.render(game), events: GameJSON.events(events)}
      else
        GameJSON.delta(previous, game, events)
      end

    payload =
      if tick_started_at_ms,
        do: Map.put(payload, :server_tick_at_ms, tick_started_at_ms),
        else: payload

    Server.broadcast(Arena.PubSub, Arena.Match.topic(id), event, payload)
  end

  def event(tick), do: if(tick == 1 or rem(tick, 30) == 0, do: "state", else: "delta")
end
