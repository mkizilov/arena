defmodule ArenaWeb.GameJSON do
  @moduledoc false

  def render(nil), do: nil

  def render(game) do
    snakes =
      Map.new(game.snakes, fn {id, snake} ->
        {to_string(id),
         %{
           body: Enum.map(:queue.to_list(snake.body), &cell/1),
           direction: snake.direction,
           alive: snake.alive,
           score: snake.score
         }}
      end)

    %{
      tick: game.tick,
      width: game.width,
      height: game.height,
      snakes: snakes,
      food: cell(game.food),
      result: game.result
    }
  end

  def events(events), do: Enum.map(events, &event/1)

  defp event({:ate, id, position}), do: %{type: :ate, player: id, cell: cell(position)}
  defp event({:died, id}), do: %{type: :died, player: id}
  defp event({:food_spawned, position}), do: %{type: :food_spawned, cell: cell(position)}
  defp event({:match_over, result}), do: %{type: :match_over, result: result}

  defp cell(nil), do: nil
  defp cell({x, y}), do: [x, y]
end
