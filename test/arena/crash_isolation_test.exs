defmodule Arena.CrashIsolationTest do
  use ExUnit.Case, async: true

  alias Arena.{Lobby, Match, Matchmaker}

  defp create_match(opts \\ []) do
    id = "isolation-#{System.unique_integer([:positive, :monotonic])}"
    :ok = Phoenix.PubSub.subscribe(Arena.PubSub, Match.topic(id))

    {:ok, pid} =
      Matchmaker.start_match(id, Keyword.merge([seed: {1, 2, 3}, countdown_ms: 0], opts))

    on_exit(fn ->
      case Horde.Registry.lookup(Arena.MatchRegistry, id) do
        [{_, _}] -> Match.stop(id)
        [] -> :ok
      end
    end)

    assert :ok = Match.join(id, :a)
    assert :ok = Match.join(id, :b)
    assert_receive {:match_status, ^id, :running, [:a, :b]}
    {id, pid}
  end

  defp player_subscriber(id, player) do
    owner = self()

    pid =
      spawn(fn ->
        :ok = Phoenix.PubSub.subscribe(Arena.PubSub, Match.topic(id))
        send(owner, {:subscribed, player})
        wait_for_recovery(owner, player)
      end)

    on_exit(fn -> send(pid, :stop) end)
    assert_receive {:subscribed, ^player}
  end

  defp wait_for_recovery(owner, player) do
    receive do
      {:match_recovered, id, _pid} -> send(owner, {:player_notified, player, id})
      :stop -> :ok
      _other -> wait_for_recovery(owner, player)
    end
  end

  test "a killed match recovers and notifies subscribers without stopping other matches" do
    {failed_id, failed_pid} = create_match(manual: true)
    {live_id, live_pid} = create_match()
    player_subscriber(failed_id, :a)
    player_subscriber(failed_id, :b)
    assert failed_id in Lobby.matches()
    assert live_id in Lobby.matches()

    assert_receive %Phoenix.Socket.Broadcast{
                     topic: "match:" <> ^live_id,
                     event: "state",
                     payload: %{state: %{tick: first_tick}}
                   },
                   1_000

    assert :ok = Match.tick(failed_id)
    before = Match.snapshot(failed_id).game

    ref = Process.monitor(failed_pid)
    Process.exit(failed_pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^failed_pid, :killed}, 1_000
    assert_receive {:match_recovering, ^failed_id}, 1_000
    assert_receive {:match_recovered, ^failed_id, recovered_pid}, 1_000
    refute recovered_pid == failed_pid
    assert Match.snapshot(failed_id).game == before
    assert_receive {:player_notified, :a, ^failed_id}, 1_000
    assert_receive {:player_notified, :b, ^failed_id}, 1_000
    assert failed_id in Lobby.matches()
    assert live_id in Lobby.matches()
    assert Process.alive?(live_pid)
    assert [{^recovered_pid, _}] = Horde.Registry.lookup(Arena.MatchRegistry, failed_id)

    assert_receive %Phoenix.Socket.Broadcast{
                     topic: "match:" <> ^live_id,
                     event: "delta",
                     payload: %{tick: tick}
                   }
                   when tick > first_tick,
                   1_000
  end

  test "normal shutdown removes a match without reporting a crash" do
    id = "idle-#{System.unique_integer([:positive, :monotonic])}"
    :ok = Phoenix.PubSub.subscribe(Arena.PubSub, Match.topic(id))
    {:ok, pid} = Match.start_match(id, idle_ms: 50)
    ref = Process.monitor(pid)
    assert id in Lobby.matches()
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1_000
    refute id in Lobby.matches()
    refute_receive {:match_ended_unexpectedly, ^id}, 100
  end
end
