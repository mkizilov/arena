defmodule Arena.MatchStateTest do
  use ExUnit.Case, async: true

  alias Arena.{Game, Match, MatchState}

  defp legacy_state do
    game = Game.new([:a, :b], {1, 2, 3}) |> Map.delete(:power_up)
    %{id: "legacy", game: game, published_game: game, inputs: %{a: :up}, phase: :running}
  end

  test "unversioned and version-one states migrate sequentially without losing state" do
    old = legacy_state()
    assert {:ok, from_zero} = MatchState.upgrade(old)
    assert {:ok, from_one} = MatchState.upgrade(Map.put(old, :version, 1))
    assert from_zero == from_one
    assert from_zero.version == 2
    assert from_zero.id == old.id
    assert from_zero.phase == old.phase
    assert from_zero.inputs == old.inputs
    assert from_zero.game.snakes == old.game.snakes
    assert from_zero.game.tick == old.game.tick
    assert from_zero.game.food == old.game.food
    assert from_zero.game.power_up != nil
    assert from_zero.game.power_up != old.game.food
    refute from_zero.game.power_up in Enum.flat_map(from_zero.game.snakes, fn {_id, snake} -> :queue.to_list(snake.body) end)
    assert from_zero.published_game.power_up == nil
    assert from_zero.published_game.rng == old.published_game.rng
    assert {:ok, ^from_zero} = MatchState.upgrade(from_zero)
  end

  test "waiting, finished and unsupported states have explicit behavior" do
    assert {:ok, %{version: 2, game: nil, published_game: nil}} =
             MatchState.upgrade(%{version: 1, game: nil, published_game: nil})

    old = legacy_state()
    finished = put_in(old.game.result, %{winners: [:a], reason: :last_alive})
    assert {:ok, migrated} = MatchState.upgrade(finished)
    assert migrated.game.power_up == nil
    assert {:error, {:unsupported_match_state_version, 3}} = MatchState.upgrade(%{version: 3})
    assert {:error, :invalid_match_state} = MatchState.upgrade(%{version: 1})
    assert {:error, :invalid_game_state} = MatchState.upgrade(%{version: 1, game: :invalid, published_game: nil})
    assert {:error, :unsupported_downgrade} = Match.code_change({:down, "2"}, old, [])
  end

  test "the first post-upgrade delta includes the newly spawned power-up" do
    old = legacy_state()
    assert ArenaWeb.GameJSON.render(old.game).power_up == nil
    assert {:ok, migrated} = MatchState.upgrade(old)
    {next, events} = Game.tick(migrated.game, %{})
    delta = ArenaWeb.GameJSON.delta(migrated.published_game, next, events)
    assert delta.power_up_removed == nil
    assert delta.power_up_added == ArenaWeb.GameJSON.render(next).power_up
  end

  test "code_change migrates a suspended running match and it continues ticking" do
    id = "upgrade-#{System.unique_integer([:positive, :monotonic])}"
    :ok = Phoenix.PubSub.subscribe(Arena.PubSub, Match.topic(id))
    {:ok, pid} = Match.start_match(id, players: [:a, :b], seed: {1, 2, 3}, countdown_ms: 0, manual: true)
    on_exit(fn ->
      case Horde.Registry.lookup(Arena.MatchRegistry, id) do
        [{_, _}] -> Match.stop(id)
        [] -> :ok
      end
    end)
    assert_receive {:match_status, ^id, :running, _}, 1_000
    assert :ok = Match.tick(id)
    :sys.replace_state(pid, fn state ->
      state
      |> Map.delete(:version)
      |> Map.update!(:game, &Map.delete(&1, :power_up))
      |> Map.update!(:published_game, &Map.delete(&1, :power_up))
    end)

    :ok = :sys.suspend(pid)
    try do
      assert :ok = :sys.change_code(pid, Match, :unversioned, [])
    after
      :sys.resume(pid)
    end

    state = :sys.get_state(pid)
    assert state.version == 2
    assert state.game.tick == 1
    assert state.game.power_up != nil
    assert :ok = Match.tick(id)
    assert Match.snapshot(id).game.tick == 2
  end

  test "a restored unversioned checkpoint is migrated before the next tick" do
    id = "upgrade-recovery-#{System.unique_integer([:positive, :monotonic])}"
    :ok = Phoenix.PubSub.subscribe(Arena.PubSub, Match.topic(id))
    {:ok, pid} = Match.start_match(id, players: [:a, :b], seed: {1, 2, 3}, countdown_ms: 0, manual: true)
    on_exit(fn ->
      case Horde.Registry.lookup(Arena.MatchRegistry, id) do
        [{_, _}] -> Match.stop(id)
        [] -> :ok
      end
    end)
    assert_receive {:match_status, ^id, :running, _}, 1_000
    assert :ok = Match.tick(id)
    {:ok, saved} = Arena.MatchStore.get(id)
    saved = saved |> Map.delete(:version) |> Map.update!(:game, &Map.delete(&1, :power_up))
      |> Map.update!(:published_game, &Map.delete(&1, :power_up))
    assert :ok = Arena.MatchStore.put(id, saved)
    Process.exit(pid, :kill)
    assert_receive {:match_recovered, ^id, new_pid}, 2_000
    assert :sys.get_state(new_pid).version == 2
    assert Match.snapshot(id).game.power_up != nil
    assert :ok = Match.tick(id)
    assert Match.snapshot(id).game.tick == 2
  end
end
