defmodule Arena.TelemetryTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog
  import Phoenix.ChannelTest
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Arena.{Match, Matchmaker, Observability}
  alias ArenaWeb.{Guest, MatchChannel, UserSocket}

  @endpoint ArenaWeb.Endpoint
  @events [
    [:arena, :match, :tick],
    [:arena, :match, :overrun],
    [:arena, :population],
    [:arena, :channel, :message],
    [:arena, :matchmaking, :wait]
  ]

  setup do
    handler = "arena-telemetry-test-#{System.unique_integer([:positive, :monotonic])}"
    :ok = :telemetry.attach_many(handler, @events, &__MODULE__.forward_event/4, self())
    on_exit(fn -> :telemetry.detach(handler) end)
    :ok
  end

  def forward_event(event, measurements, metadata, owner),
    do: send(owner, {:telemetry, event, measurements, metadata})

  defp start_match(players) do
    id = "telemetry-#{System.unique_integer([:positive, :monotonic])}"
    :ok = Phoenix.PubSub.subscribe(Arena.PubSub, Match.topic(id))
    {:ok, _pid} = Match.start_match(id, players: players, countdown_ms: 0, manual: true)

    on_exit(fn ->
      case Horde.Registry.lookup(Arena.MatchRegistry, id) do
        [{_, _}] -> Match.stop(id)
        [] -> :ok
      end
    end)

    assert_receive {:match_status, ^id, :running, _}, 1_000
    id
  end

  test "tick duration and active population report measurements at lifecycle boundaries" do
    before = Observability.snapshot()
    matches = before.active_matches + 1
    players = before.active_players + 2
    id = start_match([:a, :b])
    assert_receive {:telemetry, [:arena, :population], %{matches: ^matches, players: ^players}, %{match_id: ^id}}, 1_000
    [{pid, _}] = Horde.Registry.lookup(Arena.MatchRegistry, id)
    owner = self()
    :sys.replace_state(pid, fn state -> send(owner, {:match_logger, Logger.metadata()}); state end)
    assert_receive {:match_logger, match_metadata}
    assert match_metadata[:match_id] == id
    assert :ok = Match.tick(id)
    assert_receive {:telemetry, [:arena, :match, :tick], %{tick: 1, duration_ns: ns, duration_us: us}, %{match_id: ^id}}, 1_000
    assert ns >= 0
    assert us == div(ns, 1_000)
    assert :ok = Match.leave(id, :b)
    remaining = players - 1
    assert_receive {:telemetry, [:arena, :population], %{matches: ^matches, players: ^remaining}, %{match_id: ^id}}, 1_000
  end

  test "overrun threshold counts and logs every tick above one fifteenth second" do
    previous = Observability.snapshot().overruns
    log = capture_log(fn ->
      Arena.Telemetry.tick("overrun-test", 42, 66_666_667)
    end)

    assert log =~ "overrun-test"
    assert_receive {:telemetry, [:arena, :match, :tick], %{tick: 42, duration_ns: 66_666_667}, %{match_id: "overrun-test"}}
    assert_receive {:telemetry, [:arena, :match, :overrun], %{count: 1, duration_ns: 66_666_667}, %{match_id: "overrun-test"}}
    assert Observability.snapshot().overruns >= previous + 1
    Arena.Telemetry.tick("under-test", 1, 66_666_666)
    refute_receive {:telemetry, [:arena, :match, :overrun], _, %{match_id: "under-test"}}, 30
  end

  test "channel joins, replies and fastlane tick fanout emit direction and identity" do
    {guest, token} = Guest.issue()
    id = start_match([guest.id, "other"])
    {:ok, socket} = connect(UserSocket, %{"token" => token})
    assert {:ok, _, channel} = subscribe_and_join(socket, MatchChannel, "match:" <> id)
    player_id = guest.id
    owner = self()
    :sys.replace_state(channel.channel_pid, fn state -> send(owner, {:channel_logger, Logger.metadata()}); state end)
    assert_receive {:channel_logger, channel_metadata}
    assert channel_metadata[:match_id] == id
    assert channel_metadata[:player_id] == player_id
    assert_receive {:telemetry, [:arena, :channel, :message], %{count: 1}, %{direction: :in, event: "join", match_id: ^id, player_id: ^player_id}}
    assert_receive {:telemetry, [:arena, :channel, :message], %{count: 1}, %{direction: :out, event: "join_reply", match_id: ^id, player_id: ^player_id}}
    ref = push(channel, "ping", %{})
    assert_reply ref, :ok
    assert_receive {:telemetry, [:arena, :channel, :message], %{count: 1}, %{direction: :in, event: "ping", match_id: ^id, player_id: ^player_id}}
    assert_receive {:telemetry, [:arena, :channel, :message], %{count: 1}, %{direction: :out, event: "reply", match_id: ^id, player_id: ^player_id}}
    assert :ok = Match.tick(id)
    assert_receive {:telemetry, [:arena, :channel, :message], %{count: 1}, %{direction: :out, event: "state", match_id: ^id, player_id: nil}}
  end

  test "matchmaking measures each player's time in the queue" do
    server = start_supervised!({Matchmaker, name: nil, clock: :manual})
    assert :ok = Matchmaker.quick_play(:a, server)
    assert :ok = Matchmaker.advance(server, 4_000)
    assert :ok = Matchmaker.quick_play(:b, server)
    assert :ok = Matchmaker.advance(server, 6_000)
    assert_receive {:telemetry, [:arena, :matchmaking, :wait], %{wait_ms: 10_000}, %{match_id: id, player_id: :a}}
    assert_receive {:telemetry, [:arena, :matchmaking, :wait], %{wait_ms: 6_000}, %{match_id: ^id, player_id: :b}}

    on_exit(fn ->
      case Horde.Registry.lookup(Arena.MatchRegistry, id) do
        [{_, _}] -> Match.stop(id)
        [] -> :ok
      end
    end)
  end

  test "Prometheus scrape and custom dashboard page are restricted to loopback" do
    Arena.Telemetry.tick("scrape-test", 1, 123_000)
    conn = %{build_conn() | remote_ip: {127, 0, 0, 1}}
    response = ArenaWeb.Endpoint.call(%{conn | method: "GET", request_path: "/metrics", path_info: ["metrics"]}, [])
    assert response.status == 200
    assert response.resp_body =~ "arena_match_tick_duration_us"

    remote = %{build_conn() | remote_ip: {192, 0, 2, 1}}
    response = ArenaWeb.Endpoint.call(%{remote | method: "GET", request_path: "/metrics", path_info: ["metrics"]}, [])
    assert response.status == 403
    response = ArenaWeb.Endpoint.call(%{remote | method: "GET", request_path: "/dashboard", path_info: ["dashboard"]}, [])
    assert response.status == 403
    response = ArenaWeb.Endpoint.call(%{remote | method: "GET", request_path: "/dashboard/arena", path_info: ["dashboard", "arena"]}, [])
    assert response.status == 403

    {:ok, _view, html} = live(%{build_conn() | remote_ip: {127, 0, 0, 1}}, "/dashboard/arena")
    assert html =~ "Tick overruns"
    assert html =~ "Active players"
  end
end
