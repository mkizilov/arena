defmodule Arena.GameUpdates do
  @moduledoc "Publishes one transport update per tick using Phoenix's serializer fastlane."

  alias ArenaWeb.GameJSON

  def publish(id, previous, game, events) do
    {event, payload} =
      if game.tick == 1 or rem(game.tick, 30) == 0 do
        {"state", %{state: GameJSON.render(game), events: GameJSON.events(events)}}
      else
        {"delta", GameJSON.delta(previous, game, events)}
      end

    Phoenix.Channel.Server.broadcast(Arena.PubSub, Arena.Match.topic(id), event, payload)
  end
end
