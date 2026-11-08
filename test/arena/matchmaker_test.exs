defmodule Arena.MatchmakerTest do
  use ExUnit.Case, async: true

  alias Arena.{Lobby, Match, Matchmaker}

  setup do
    server = start_supervised!({Matchmaker, name: nil, clock: :manual})
    %{server: server}
  end

  defp cleanup_match(id) do
    on_exit(fn ->
      case Horde.Registry.lookup(Arena.MatchRegistry, id) do
        [{_, _}] -> Match.stop(id)
        [] -> :ok
      end
    end)
  end

  defp queue_player(server, player) do
    owner = self()

    pid =
      spawn(fn ->
        receive do
          :go -> :ok
        end

        send(owner, {:queued, player, Matchmaker.quick_play(player, server)})

        receive do
          {:match_found, id, ^player} -> send(owner, {:found, player, id})
          :stop -> :ok
        end
      end)

    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :kill) end)
    pid
  end

  test "two players wait ten seconds measured from the first arrival", %{server: server} do
    assert :ok = Matchmaker.quick_play(:a, server)
    assert :ok = Matchmaker.advance(server, 9_999)
    assert :ok = Matchmaker.quick_play(:b, server)
    refute_receive {:match_found, _, _}, 20
    assert :ok = Matchmaker.advance(server, 1)
    assert_receive {:match_found, id, :a}
    cleanup_match(id)
    assert_receive {:match_found, ^id, :b}
    assert Matchmaker.queued(server) == []
    assert %{players: [:a, :b], phase: :countdown} = Match.snapshot(id)
  end

  test "one player remains queued past the deadline and a second starts the match", %{server: server} do
    assert :ok = Matchmaker.quick_play(:a, server)
    assert :ok = Matchmaker.advance(server, 20_000)
    assert Matchmaker.queued(server) == [:a]
    assert :ok = Matchmaker.quick_play(:b, server)
    assert_receive {:match_found, id, :a}
    cleanup_match(id)
    assert_receive {:match_found, ^id, :b}
  end

  test "eight concurrent joins form one match immediately", %{server: server} do
    players = for n <- 1..8, do: queue_player(server, n)
    Enum.each(players, &send(&1, :go))
    for n <- 1..8, do: assert_receive({:queued, ^n, :ok}, 1_000)
    assert_receive {:found, _player, id}, 1_000
    cleanup_match(id)
    for _ <- 1..7, do: assert_receive({:found, _, ^id}, 1_000)
    assert Matchmaker.queued(server) == []
    assert length(Match.snapshot(id).players) == 8
  end

  test "disconnected queued processes are removed and cannot fill a match", %{server: server} do
    pid = queue_player(server, :gone)
    send(pid, :go)
    assert_receive {:queued, :gone, :ok}
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}
    assert Matchmaker.queued(server) == []
    assert :ok = Matchmaker.quick_play(:remaining, server)
    assert :ok = Matchmaker.advance(server, 10_000)
    assert Matchmaker.queued(server) == [:remaining]
    refute_receive {:match_found, _, _}, 20
  end

  test "duplicate queue IDs and cancellation are handled without retaining a timer", %{server: server} do
    assert :ok = Matchmaker.quick_play(:a, server)
    assert {:error, :already_queued} = Matchmaker.quick_play(:a, server)
    assert :ok = Matchmaker.cancel(:a, server)
    assert {:error, :not_queued} = Matchmaker.cancel(:a, server)
    assert :ok = Matchmaker.advance(server, 20_000)
    assert :ok = Matchmaker.quick_play(:a, server)
    assert :ok = Matchmaker.quick_play(:b, server)
    refute_receive {:match_found, _, _}, 20
    assert :ok = Matchmaker.advance(server, 10_000)
    assert_receive {:match_found, id, :a}
    cleanup_match(id)
    assert_receive {:match_found, ^id, :b}
  end

  test "private room codes join only private rooms and never appear in the public lobby" do
    assert {:ok, code} = Matchmaker.create_private(:host)
    id = "room-" <> code
    cleanup_match(id)
    assert byte_size(code) == 8
    assert :ok = Matchmaker.join_private(String.downcase(code), :guest)
    assert %{visibility: :private, players: [:host, :guest]} = Match.snapshot(id)
    assert {:error, :already_joined} = Matchmaker.join_private(code, :guest)
    assert {:error, :not_found} = Matchmaker.join_private("invalid", :guest)
    refute Enum.any?(Lobby.open_matches(), &(&1.id == id))
  end

  test "the lobby publishes public player counts and removes closed matches" do
    :ok = Phoenix.PubSub.subscribe(Arena.PubSub, Lobby.topic())
    id = "lobby-test-#{System.unique_integer([:positive, :monotonic])}"
    {:ok, _pid} = Match.start_match(id, countdown_ms: 60_000)
    cleanup_match(id)
    assert_lobby_count(id, 0)
    assert :ok = Match.join(id, :a)
    assert_lobby_count(id, 1)
    assert :ok = Match.join(id, :b)
    assert_lobby_count(id, 2)
    for player <- 3..8, do: assert(:ok = Match.join(id, player))
    assert_lobby_count(id, nil)
    :ok = Match.stop(id)
    assert_lobby_count(id, nil)
  end

  defp assert_lobby_count(id, count) do
    receive do
      {:lobby_updated, rooms} ->
        room = Enum.find(rooms, &(&1.id == id))

        if (room && room.player_count) == count,
          do: :ok,
          else: assert_lobby_count(id, count)
    after
      1_000 -> flunk("did not receive lobby count #{inspect(count)} for #{id}")
    end
  end
end
