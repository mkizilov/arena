defmodule Arena.GameUpdatesTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Arena.{Game, GameUpdates}
  alias ArenaWeb.GameJSON

  defmodule CountingSerializer do
    @moduledoc false
    def fastlane!(message) do
      send(self(), :encoded)
      {:encoded, message.payload}
    end
  end

  defp apply_delta(snapshot, delta) do
    snakes =
      Enum.reduce(delta.moves, snapshot.snakes, fn {id, move}, snakes ->
        Map.update!(snakes, id, fn snake ->
          body = [move.head | snake.body]
          body = if move.tail_moved, do: Enum.drop(body, -1), else: body
          %{snake | body: body, direction: move.direction}
        end)
      end)

    snakes = Enum.reduce(delta.deaths, snakes, &Map.update!(&2, &1, fn snake -> %{snake | alive: false} end))
    snakes = Enum.reduce(delta.scores, snakes, fn {id, score}, acc -> Map.update!(acc, id, &%{&1 | score: score}) end)

    %{
      snapshot
      | tick: delta.tick,
        snakes: snakes,
        food: Map.get(delta, :food_added, snapshot.food),
        result: Map.get(delta, :result, snapshot.result)
    }
  end

  property "applying every delta reproduces the complete published state" do
    direction = member_of([:up, :down, :left, :right])

    check all seed <- tuple({integer(1..100_000), integer(1..100_000), integer(1..100_000)}),
              inputs <- list_of(fixed_map(%{a: direction, b: direction, c: direction}), max_length: 120) do
      initial = Game.new([:a, :b, :c], seed)

      Enum.reduce_while(inputs, {initial, GameJSON.render(initial)}, fn input, {previous, snapshot} ->
        if previous.result do
          {:halt, {previous, snapshot}}
        else
          {next, events} = Game.tick(previous, input)
          delta = GameJSON.delta(previous, next, events)
          reconstructed = apply_delta(snapshot, delta)
          assert reconstructed == GameJSON.render(next)
          {:cont, {next, reconstructed}}
        end
      end)
    end
  end

  test "deltas preserve food, growth, death, scores, results and forfeits" do
    initial = Game.new([:a, :b, :c], {1, 2, 3})
    initial = %{initial | food: {6, 4}}
    {eaten, events} = Game.tick(initial, %{})
    delta = GameJSON.delta(initial, eaten, events)
    assert delta.food_removed == [6, 4]
    assert delta.food_added == GameJSON.render(eaten).food
    assert delta.scores["a"] == 1
    refute delta.moves["a"].tail_moved
    assert apply_delta(GameJSON.render(initial), delta) == GameJSON.render(eaten)

    forfeited = put_in(eaten.snakes.a.alive, false)
    {next, events} = Game.tick(forfeited, %{})
    delta = GameJSON.delta(eaten, next, [{:died, :a} | events])
    assert "a" in delta.deaths
    refute Map.has_key?(delta.moves, "a")
    assert apply_delta(GameJSON.render(eaten), delta) == GameJSON.render(next)
  end

  test "a fatal move preserves the final body and result" do
    game = Game.new([:a, :b], {1, 2, 3})
    game = put_in(game.snakes.b.body, :queue.from_list([{39, 4}, {38, 4}, {37, 4}]))
    {next, events} = Game.tick(game, %{})
    delta = GameJSON.delta(game, next, events)
    assert delta.moves["b"].head == [40, 4]
    assert "b" in delta.deaths
    assert delta.result == %{winners: [:a], reason: :last_alive}
    assert apply_delta(GameJSON.render(game), delta) == GameJSON.render(next)
  end

  test "broadcasts full state at tick one and every thirty ticks" do
    id = "updates-#{System.unique_integer([:positive, :monotonic])}"
    topic = Arena.Match.topic(id)
    :ok = Phoenix.PubSub.subscribe(Arena.PubSub, topic)
    game = Game.new([:a, :b], {1, 2, 3})
    assert :ok = GameUpdates.publish(id, game, %{game | tick: 1}, [])
    assert_receive %Phoenix.Socket.Broadcast{topic: ^topic, event: "state", payload: %{state: %{tick: 1}}}
    assert :ok = GameUpdates.publish(id, game, %{game | tick: 2}, [])
    assert_receive %Phoenix.Socket.Broadcast{topic: ^topic, event: "delta", payload: %{tick: 2}}
    assert :ok = GameUpdates.publish(id, game, %{game | tick: 30}, [])
    assert_receive %Phoenix.Socket.Broadcast{topic: ^topic, event: "state", payload: %{state: %{tick: 30}}}
  end

  test "fastlane encodes once for multiple subscribers using the same serializer" do
    broadcast = %Phoenix.Socket.Broadcast{topic: "match:test", event: "delta", payload: %{tick: 2}}
    lane = {self(), {:fastlane, self(), CountingSerializer, []}}
    assert :ok = Phoenix.Channel.Server.dispatch([lane, lane], :none, broadcast)
    assert_receive :encoded
    assert_receive {:encoded, %{tick: 2}}
    assert_receive {:encoded, %{tick: 2}}
    refute_receive :encoded, 20
  end
end
