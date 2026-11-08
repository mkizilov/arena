defmodule Arena.GameUpdates do
  @moduledoc "Publishes one transport update per tick using Phoenix's serializer fastlane."

  alias ArenaWeb.GameJSON

  def snapshot(id, game) do
    Phoenix.Channel.Server.broadcast(
      Arena.PubSub,
      Arena.Match.topic(id),
      "state",
      %{state: GameJSON.render(game), events: []}
    )
  end

  def publish(id, previous, game, events) do
    event = event(game.tick)

    payload =
      if event == "state" do
        %{state: GameJSON.render(game), events: GameJSON.events(events)}
      else
        GameJSON.delta(previous, game, events)
      end

    Phoenix.Channel.Server.broadcast(Arena.PubSub, Arena.Match.topic(id), event, payload)
  end

  def event(tick), do: if(tick == 1 or rem(tick, 30) == 0, do: "state", else: "delta")
end
