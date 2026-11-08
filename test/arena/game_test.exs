defmodule Arena.GameTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Arena.Game
  alias Arena.Game.Snake

  defp snake(cells, direction, score \\ 0) do
    %Snake{body: :queue.from_list(cells), direction: direction, score: score}
  end

  defp game(snakes, food \\ {20, 20}) do
    %{Game.new([:a, :b], {1, 2, 3}) | snakes: Map.new(snakes), food: food, power_up: {30, 29}}
  end

  defp cells(snake), do: :queue.to_list(snake.body)

  test "initializes a seeded game with unique free food and validates players" do
    state = Game.new(Enum.to_list(1..8), {1, 2, 3})
    assert state == Game.new(Enum.to_list(1..8), {1, 2, 3})
    assert {state.width, state.height} == {40, 30}
    assert map_size(state.snakes) == 8
    refute state.food in Enum.flat_map(state.snakes, fn {_, s} -> cells(s) end)
    refute state.power_up in Enum.flat_map(state.snakes, fn {_, s} -> cells(s) end)
    assert state.power_up != state.food
    assert_raise ArgumentError, fn -> Game.new([:a], {1, 2, 3}) end
    assert_raise ArgumentError, fn -> Game.new([:a, :a], {1, 2, 3}) end
    assert_raise ArgumentError, fn -> Game.new(Enum.to_list(1..9), {1, 2, 3}) end
  end

  test "moves, ignores reversal and invalid inputs, and accepts a turn" do
    state = game(a: snake([{5, 5}, {4, 5}, {3, 5}], :right), b: snake([{20, 5}], :right))
    {next, []} = Game.tick(state, %{a: :left, b: :invalid})
    assert cells(next.snakes.a) == [{6, 5}, {5, 5}, {4, 5}]
    assert next.snakes.b.direction == :right
    {next, []} = Game.tick(next, %{a: :up})
    assert hd(cells(next.snakes.a)) == {6, 4}
  end

  test "food grows and scores once and is replaced on a free cell" do
    state = game([a: snake([{5, 5}, {4, 5}], :right), b: snake([{20, 5}], :right)], {6, 5})
    {next, events} = Game.tick(state, %{})
    assert {:ate, :a, {6, 5}} in events
    assert {:food_spawned, next.food} in events
    assert next.snakes.a.score == 1
    assert cells(next.snakes.a) == [{6, 5}, {5, 5}, {4, 5}]
    refute next.food in Enum.flat_map(next.snakes, fn {_, s} -> cells(s) end)
    assert next.food != next.power_up
  end

  test "walls and bodies kill and end the match" do
    state = game(a: snake([{39, 5}, {38, 5}], :right), b: snake([{20, 5}], :right))
    {next, events} = Game.tick(state, %{})
    assert {:died, :a} in events
    assert {:match_over, %{winners: [:b], reason: :last_alive}} in events
    refute next.snakes.a.alive
    assert Game.tick(next, %{}) == {next, []}

    state = game(a: snake([{5, 5}, {5, 6}, {6, 6}, {6, 5}, {7, 5}], :up), b: snake([{20, 5}], :right))
    {next, _} = Game.tick(state, %{a: :right})
    refute next.snakes.a.alive
  end

  test "head-on collisions and head swaps kill both snakes simultaneously" do
    for {a, b} <- [
          {[{5, 5}], [{7, 5}]},
          {[{5, 5}], [{6, 5}]}
        ] do
      state = game(a: snake(a, :right), b: snake(b, :left))
      {next, events} = Game.tick(state, %{})
      refute next.snakes.a.alive
      refute next.snakes.b.alive
      assert {:died, :a} in events
      assert {:died, :b} in events
      assert {:match_over, %{winners: [], reason: :simultaneous_death}} in events
    end
  end

  test "vacated tails are safe, but retained tails and other bodies are not" do
    state = game(a: snake([{4, 5}], :right), b: snake([{6, 5}, {5, 5}], :right))
    {next, _} = Game.tick(state, %{})
    assert next.snakes.a.alive
    state = %{state | food: {7, 5}}
    {next, _} = Game.tick(state, %{})
    refute next.snakes.a.alive
  end

  test "a snake that dies on food neither scores nor grows" do
    state = game([a: snake([{5, 5}], :right), b: snake([{7, 5}], :left)], {6, 5})
    {next, events} = Game.tick(state, %{})
    assert next.food == {6, 5}
    assert next.snakes.a.score == 0
    assert length(cells(next.snakes.a)) == 1
    refute Enum.any?(events, fn event -> elem(event, 0) == :ate end)
  end

  test "collecting a power-up gives five points without growth and respawns on a free cell" do
    state = game(a: snake([{5, 5}, {4, 5}], :right), b: snake([{20, 5}], :right))
    state = %{state | power_up: {6, 5}}
    {next, events} = Game.tick(state, %{})
    assert {:power_up_collected, :a, {6, 5}} in events
    assert {:power_up_spawned, next.power_up} in events
    assert next.snakes.a.score == 5
    assert length(cells(next.snakes.a)) == 2
    refute next.power_up == next.food
    refute next.power_up in Enum.flat_map(next.snakes, fn {_, snake} -> cells(snake) end)
  end

  test "a fatal collision on a power-up does not collect it" do
    state = game(a: snake([{5, 5}], :right), b: snake([{7, 5}], :left))
    state = %{state | power_up: {6, 5}}
    {next, events} = Game.tick(state, %{})
    assert next.power_up == {6, 5}
    assert next.snakes.a.score == 0
    assert next.snakes.b.score == 0
    refute Enum.any?(events, fn event -> elem(event, 0) == :power_up_collected end)
  end

  test "food and power-up consumed on the same tick respawn in distinct free cells" do
    state = game([a: snake([{5, 5}, {4, 5}], :right), b: snake([{20, 5}, {19, 5}], :right)], {6, 5})
    state = %{state | power_up: {21, 5}}
    {next, events} = Game.tick(state, %{})
    assert {:ate, :a, {6, 5}} in events
    assert {:power_up_collected, :b, {21, 5}} in events
    assert next.snakes.a.score == 1
    assert next.snakes.b.score == 5
    assert length(cells(next.snakes.a)) == 3
    assert length(cells(next.snakes.b)) == 2
    assert next.food != next.power_up
    occupied = Enum.flat_map(next.snakes, fn {_, snake} -> cells(snake) end)
    refute next.food in occupied
    refute next.power_up in occupied
  end

  test "after 2700 ticks the highest scores win, including ties" do
    state = game(a: snake([{5, 5}], :right, 2), b: snake([{20, 5}], :right, 2))
    {next, events} = Game.tick(%{state | tick: 2699}, %{})
    assert next.result == %{winners: [:a, :b], reason: :time_limit}
    assert {:match_over, next.result} in events
    state = put_in(state.snakes.a.score, 3)
    {next, _} = Game.tick(%{state | tick: 2699}, %{})
    assert next.result.winners == [:a]
  end

  test "no food is spawned when the board is full" do
    dead = %{snake([{1, 1}], :right) | alive: false}
    state = game([a: snake([{0, 0}, {0, 1}, {1, 1}], :right), b: dead], {1, 0})
    state = %{state | width: 2, height: 2, power_up: nil}
    {next, events} = Game.tick(state, %{})
    assert {:ate, :a, {1, 0}} in events
    assert next.food == nil
    refute Enum.any?(events, fn event -> elem(event, 0) == :food_spawned end)
  end

  property "random input sequences preserve invariants and replay deterministically" do
    direction = member_of([:up, :down, :left, :right])

    check all seed <- tuple({integer(1..100_000), integer(1..100_000), integer(1..100_000)}),
              inputs <- list_of(fixed_map(%{a: direction, b: direction, c: direction}), max_length: 100) do
      initial = Game.new([:a, :b, :c], seed)

      {final, _, _} =
        Enum.reduce(inputs, {initial, initial, %{}}, fn input, {state, replay, counts} ->
          {next, events} = Game.tick(state, input)
          assert {next, events} == Game.tick(replay, input)

          counts = Enum.reduce(events, counts, fn
            {:ate, id, _}, acc -> Map.update(acc, id, {1, 0}, fn {food, powers} -> {food + 1, powers} end)
            {:power_up_collected, id, _}, acc -> Map.update(acc, id, {0, 1}, fn {food, powers} -> {food, powers + 1} end)
            _, acc -> acc
          end)

          live_cells =
            next.snakes
            |> Enum.filter(fn {_, snake} -> snake.alive end)
            |> Enum.flat_map(fn {_, snake} -> cells(snake) end)

          assert length(live_cells) == MapSet.size(MapSet.new(live_cells))

          for {id, snake} <- next.snakes do
            {food, powers} = Map.get(counts, id, {0, 0})
            assert length(cells(snake)) == 3 + food
            assert snake.score == food + 5 * powers
            assert snake.score >= state.snakes[id].score
          end

          {next, next, counts}
        end)

      assert final == Enum.reduce(inputs, initial, fn input, state -> elem(Game.tick(state, input), 0) end)
    end
  end
end
