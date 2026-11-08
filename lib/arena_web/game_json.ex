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
      power_up: cell(Map.get(game, :power_up)),
      result: game.result
    }
  end

  def events(events), do: Enum.map(events, &event/1)

  @doc "Builds a wire delta between consecutive published game states."
  def delta(previous, current, events) do
    {moves, deaths, scores} =
      Enum.reduce(current.snakes, {%{}, [], %{}}, fn {id, snake}, {moves, deaths, scores} ->
        old = Map.fetch!(previous.snakes, id)
        key = to_string(id)
        old_body = :queue.to_list(old.body)
        new_body = :queue.to_list(snake.body)

        moves =
          if old_body == new_body do
            moves
          else
            move = %{
              head: cell(hd(new_body)),
              tail_moved: length(old_body) == length(new_body),
              direction: snake.direction
            }

            Map.put(moves, key, move)
          end

        deaths = if old.alive and not snake.alive, do: [key | deaths], else: deaths
        scores = if old.score != snake.score, do: Map.put(scores, key, snake.score), else: scores
        {moves, deaths, scores}
      end)

    delta = %{tick: current.tick, moves: moves, deaths: Enum.sort(deaths), scores: scores, events: events(events)}

    delta =
      if previous.food != current.food do
        Map.merge(delta, %{food_removed: cell(previous.food), food_added: cell(current.food)})
      else
        delta
      end

    delta =
      if Map.get(previous, :power_up) != Map.get(current, :power_up) do
        Map.merge(delta, %{power_up_removed: cell(Map.get(previous, :power_up)), power_up_added: cell(Map.get(current, :power_up))})
      else
        delta
      end

    if previous.result != current.result, do: Map.put(delta, :result, current.result), else: delta
  end

  defp event({:ate, id, position}), do: %{type: :ate, player: id, cell: cell(position)}
  defp event({:died, id}), do: %{type: :died, player: id}
  defp event({:food_spawned, position}), do: %{type: :food_spawned, cell: cell(position)}
  defp event({:power_up_collected, id, position}), do: %{type: :power_up_collected, player: id, cell: cell(position)}
  defp event({:power_up_spawned, position}), do: %{type: :power_up_spawned, cell: cell(position)}
  defp event({:match_over, result}), do: %{type: :match_over, result: result}

  defp cell(nil), do: nil
  defp cell({x, y}), do: [x, y]
end
