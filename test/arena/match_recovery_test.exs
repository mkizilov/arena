defmodule Arena.MatchRecoveryTest do
  use ExUnit.Case, async: false

  alias Arena.{Match, MatchStore}

  defp start_match(opts \\ []) do
    id = "recovery-#{System.unique_integer([:positive, :monotonic])}"
    :ok = Phoenix.PubSub.subscribe(Arena.PubSub, Match.topic(id))
    {:ok, _pid} = Match.start_match(id, Keyword.merge([players: [:a, :b], seed: {1, 2, 3}, countdown_ms: 0, manual: true], opts))

    on_exit(fn ->
      case Registry.lookup(Arena.MatchRegistry, id) do
        [{pid, _}] -> DynamicSupervisor.terminate_child(Arena.MatchSupervisor, pid)
        [] -> :ok
      end
    end)

    assert_receive {:match_status, ^id, :running, _}, 1_000
    id
  end

  defp session do
    pid = spawn(fn ->
      receive do
        :stop -> :ok
      end
    end)
    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :kill) end)
    pid
  end

  defp crash_and_wait(id) do
    [{old, _}] = Registry.lookup(Arena.MatchRegistry, id)
    ref = Process.monitor(old)
    Process.exit(old, :kill)
    assert_receive {:DOWN, ^ref, :process, ^old, :killed}, 1_000
    assert_receive {:match_recovered, ^id, new}, 2_000
    refute new == old
    new
  end

  test "reconnect preserves the snake, discards buffered input, and survives a match crash" do
    id = start_match(reconnect_ms: 2_000)
    first = session()
    second = session()
    assert {:ok, _} = Match.attach(id, :a, first)
    assert {:ok, _} = Match.attach(id, :b, second)
    assert :ok = Match.input(id, :a, :up)
    Process.exit(first, :kill)
    assert_receive {:match_disconnected, ^id, :a}, 1_000
    assert {:error, :disconnected} = Match.input(id, :a, :up)
    assert :ok = Match.tick(id)
    before = Match.snapshot(id).game
    assert {:value, {6, 4}} = :queue.peek(before.snakes.a.body)
    [{pid, _}] = Registry.lookup(Arena.MatchRegistry, id)
    deadline = :sys.get_state(pid).disconnects[:a]
    recovered = crash_and_wait(id)
    assert :sys.get_state(recovered).disconnects[:a] == deadline
    assert Match.snapshot(id).game == before
    {_timer, old_token} = :sys.get_state(recovered).disconnect_timers[:a]
    replacement = session()
    assert {:ok, %{game: ^before}} = Match.attach(id, :a, replacement)
    assert_receive {:match_reconnected, ^id, :a}
    send(recovered, {:disconnect_expired, :a, old_token})
    assert :a in Match.snapshot(id).players
    assert :ok = Match.input(id, :a, :up)
    assert :ok = Match.tick(id)
    assert {:value, {6, 3}} = :queue.peek(Match.snapshot(id).game.snakes.a.body)
  end

  test "a buffered input is restored if the process crashes before the tick" do
    id = start_match()
    assert :ok = Match.input(id, :a, :up)
    crash_and_wait(id)
    assert :ok = Match.tick(id)
    assert {:value, {5, 3}} = :queue.peek(Match.snapshot(id).game.snakes.a.body)
  end

  test "the last disconnected session expires and forfeits after the grace period" do
    id = start_match(reconnect_ms: 50)
    first = session()
    assert {:ok, _} = Match.attach(id, :a, first)
    Process.exit(first, :kill)
    assert_receive {:match_disconnected, ^id, :a}, 1_000
    assert_receive {:match_status, ^id, :running, [:b]}, 1_000
    assert :ok = Match.tick(id)
    assert Match.snapshot(id).game.result == %{winners: [:b], reason: :last_alive}
    assert {:error, :finished} = Match.attach(id, :a, self())
  end

  test "one of several sessions disconnecting does not start a grace timer" do
    id = start_match(reconnect_ms: 100)
    first = session()
    second = session()
    assert {:ok, _} = Match.attach(id, :a, first)
    assert {:ok, _} = Match.attach(id, :a, second)
    Process.exit(first, :kill)
    refute_receive {:match_disconnected, ^id, :a}, 150
    assert :a in Match.snapshot(id).players
    Process.exit(second, :kill)
    assert_receive {:match_disconnected, ^id, :a}, 1_000
  end

  @tag timeout: 120_000
  test "fifty seeded chaos games resume after randomly placed kills and finish" do
    {_, rng} = :rand.uniform_s(10, :rand.seed_s(:exsss, {42, 71, 99}))

    Enum.reduce(1..50, rng, fn _run, rng ->
      id = start_match()
      {first, rng} = :rand.uniform_s(7, rng)
      {count, rng} = :rand.uniform_s(3, rng)
      kills = for offset <- 0..(count - 1), into: MapSet.new(), do: first + 7 * offset

      result = Enum.reduce_while(1..40, nil, fn tick, _ ->
        if MapSet.member?(kills, tick) do
          before = Match.snapshot(id).game
          {:ok, checkpoint} = MatchStore.get(id)
          assert checkpoint.game == before
          crash_and_wait(id)
          assert Match.snapshot(id).game == before
        end

        assert :ok = Match.tick(id)
        case Match.snapshot(id).game.result do
          nil -> {:cont, nil}
          result -> {:halt, result}
        end
      end)

      assert result != nil
      [{pid, _}] = Registry.lookup(Arena.MatchRegistry, id)
      :ok = DynamicSupervisor.terminate_child(Arena.MatchSupervisor, pid)
      assert :error = MatchStore.get(id)
      :ok = Phoenix.PubSub.unsubscribe(Arena.PubSub, Match.topic(id))
      rng
    end)
  end
end
