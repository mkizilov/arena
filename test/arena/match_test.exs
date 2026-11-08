defmodule Arena.MatchTest do
  use ExUnit.Case, async: true

  alias Arena.Match

  defp start_match(opts \\ []) do
    id = "test-#{System.unique_integer([:positive, :monotonic])}"
    :ok = Phoenix.PubSub.subscribe(Arena.PubSub, Match.topic(id))
    {:ok, pid} = Match.start_match(id, Keyword.merge([seed: {1, 2, 3}, manual: true], opts))

    on_exit(fn ->
      if Process.alive?(pid), do: DynamicSupervisor.terminate_child(Arena.MatchSupervisor, pid)
    end)

    {id, pid}
  end

  defp start_running(opts \\ []) do
    {id, pid} = start_match(Keyword.merge([countdown_ms: 0], opts))
    assert :ok = Match.join(id, :a)
    assert :ok = Match.join(id, :b)
    assert_receive {:match_status, ^id, :running, [:a, :b]}
    {id, pid}
  end

  test "registers one match per ID, accepts up to eight players and rejects duplicates" do
    {id, _pid} = start_match(countdown_ms: 60_000)
    assert {:error, {:already_started, _}} = Match.start_match(id)
    assert :ok = Match.join(id, 1)
    assert {:error, :already_joined} = Match.join(id, 1)
    for player <- 2..8, do: assert(:ok = Match.join(id, player))
    assert {:error, :full} = Match.join(id, 9)
    assert %{phase: :countdown, players: [1, 2, 3, 4, 5, 6, 7, 8]} = Match.snapshot(id)
    assert {:error, :not_running} = Match.input(id, 1, :up)
  end

  test "leaving a countdown returns to waiting and a later join starts a new countdown" do
    {id, _pid} = start_match(countdown_ms: 60_000)
    assert :ok = Match.join(id, :a)
    assert :ok = Match.join(id, :b)
    assert :ok = Match.leave(id, :b)
    assert {:error, :not_joined} = Match.leave(id, :b)
    assert %{phase: :waiting, players: [:a], game: nil} = Match.snapshot(id)
    assert :ok = Match.join(id, :c)
    assert %{phase: :countdown, players: [:a, :c]} = Match.snapshot(id)
  end

  test "an idle waiting match shuts down and unregisters" do
    {id, pid} = start_match(idle_ms: 30)
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1_000
    assert Registry.lookup(Arena.MatchRegistry, id) == []
  end

  test "latest input is applied once per manual tick and each tick is broadcast" do
    {id, _pid} = start_running()
    assert {:error, :started} = Match.join(id, :c)
    assert {:error, :not_joined} = Match.input(id, :c, :up)
    assert {:error, :invalid_direction} = Match.input(id, :a, :invalid)
    assert :ok = Match.input(id, :a, :down)
    assert :ok = Match.input(id, :a, :up)
    assert :ok = Match.tick(id)
    assert_receive %Phoenix.Socket.Broadcast{topic: "match:" <> ^id, event: "state", payload: %{state: %{tick: 1}}}
    game = Match.snapshot(id).game
    assert game.tick == 1
    assert {:value, {5, 3}} = :queue.peek(game.snakes.a.body)
    assert :ok = Match.tick(id)
    assert_receive %Phoenix.Socket.Broadcast{topic: "match:" <> ^id, event: "delta", payload: %{tick: 2}}
    game = Match.snapshot(id).game
    assert game.tick == 2
    assert {:value, {5, 2}} = :queue.peek(game.snakes.a.body)
  end

  test "leaving during a match forfeits and finishes on the next tick, then shuts down" do
    {id, pid} = start_running(grace_ms: 30)
    ref = Process.monitor(pid)
    assert :ok = Match.leave(id, :a)
    assert {:error, :not_joined} = Match.input(id, :a, :up)
    assert :ok = Match.tick(id)
    assert_receive %Phoenix.Socket.Broadcast{topic: "match:" <> ^id, payload: %{events: events}}
    game = Match.snapshot(id).game
    assert %{type: :died, player: :a} in events
    assert %{type: :match_over, result: %{reason: :last_alive, winners: [:b]}} in events
    assert game.result.winners == [:b]
    assert_receive {:match_status, ^id, :finished, [:b]}
    assert {:error, :not_manual_running} = Match.tick(id)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1_000
  end

  test "a game ending naturally broadcasts its result" do
    {id, _pid} = start_running()

    Enum.reduce_while(1..40, nil, fn _, _ ->
      assert :ok = Match.tick(id)
      assert_receive %Phoenix.Socket.Broadcast{topic: "match:" <> ^id, payload: %{events: events}}
      game = Match.snapshot(id).game

      if game.result do
        assert %{type: :match_over, result: game.result} in events
        {:halt, game.result}
      else
        {:cont, nil}
      end
    end)
    |> then(fn result -> assert result != nil end)

    assert %{phase: :finished} = Match.snapshot(id)
  end

  test "automatic mode schedules and broadcasts ticks without manual intervention" do
    {id, _pid} = start_running(manual: false)
    assert {:error, :not_manual_running} = Match.tick(id)
    assert_receive %Phoenix.Socket.Broadcast{topic: "match:" <> ^id, event: "state", payload: %{state: %{tick: 1}}}, 1_000
    assert_receive %Phoenix.Socket.Broadcast{topic: "match:" <> ^id, event: "delta", payload: %{tick: 2}}, 1_000
  end
end
