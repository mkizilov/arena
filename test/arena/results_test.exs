defmodule Arena.ResultsTest do
  use ExUnit.Case, async: false
  import Ecto.Query
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Arena.{Leaderboard, Match, MatchStore, Repo, Results}
  alias Arena.Persistence.{MatchResult, Player, PlayerStat}
  alias Ecto.Adapters.SQL.Sandbox

  @endpoint ArenaWeb.Endpoint

  setup do
    owner = Sandbox.start_owner!(Repo, shared: true)
    on_exit(fn -> Sandbox.stop_owner(owner) end)
    await_pending()
    Repo.delete_all(PlayerStat)
    Repo.delete_all(MatchResult)
    Repo.delete_all(Player)
    :ok
  end

  defp result(id, scores, winners) do
    %{
      match_id: id,
      result_id: id,
      duration_ms: 12_000,
      winner_ids: winners,
      reason: "time_limit",
      final_scores: scores,
      player_names: Map.new(scores, fn {player, _} -> {player, "Name-#{player}"} end)
    }
  end

  defp start_match(players) do
    id = "persist-#{System.unique_integer([:positive, :monotonic])}"
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

  defp subscribe_telemetry do
    handler = "arena-results-test-#{System.unique_integer([:positive, :monotonic])}"
    events = [[:arena, :result_writer, :start], [:arena, :result_writer, :retry]]

    :ok =
      :telemetry.attach_many(
        handler,
        events,
        fn event, _measurements, metadata, owner ->
          send(owner, {event, metadata.match_id})
        end,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler) end)
  end

  defp await_pending do
    :ok =
      Enum.reduce_while(1..1_600, :timeout, fn _, _ ->
        if MatchStore.pending_results() == [] do
          {:halt, :ok}
        else
          Process.sleep(20)
          {:cont, :timeout}
        end
      end)

    assert MatchStore.pending_results() == []
  end

  defp await_html(view, text, attempts \\ 100)
  defp await_html(_view, text, 0), do: flunk("leaderboard did not update with #{text}")

  defp await_html(view, text, attempts) do
    if render(view) =~ text do
      :ok
    else
      Process.sleep(20)
      await_html(view, text, attempts - 1)
    end
  end

  test "transactions record ties and update statistics exactly once per match" do
    first = result("first", %{"a" => 4, "b" => 7}, ["a", "b"])
    assert {:ok, :inserted} = Results.record(first)
    assert {:ok, :duplicate} = Results.record(first)
    assert Repo.get!(MatchResult, "first").winner_ids == ["a", "b"]
    assert Repo.get!(Player, "a").display_name == "Name-a"
    assert %{wins: 1, best_score: 4, matches_played: 1} = Repo.get!(PlayerStat, "a")

    second = result("second", %{"a" => 5, "b" => 10}, ["a"])
    assert {:ok, :inserted} = Results.record(second)
    assert %{wins: 2, best_score: 5, matches_played: 2} = Repo.get!(PlayerStat, "a")
    assert %{wins: 1, best_score: 10, matches_played: 2} = Repo.get!(PlayerStat, "b")
    assert hd(Leaderboard.top(:wins)).guest_id == "a"
    assert hd(Leaderboard.top(:best_score)).guest_id == "b"

    reused = %{result("first", %{"a" => 3}, ["a"]) | result_id: "new-instance"}
    assert {:ok, :inserted} = Results.record(reused)
    assert Repo.aggregate(from(r in MatchResult, where: r.match_id == "first"), :count) == 2
    assert %{wins: 3, best_score: 5, matches_played: 3} = Repo.get!(PlayerStat, "a")
  end

  test "builds duration, winners, scores and verified display names from the game" do
    game = Arena.Game.new([:a, :b], {1, 2, 3})
    game = %{game | tick: 150, result: %{winners: [:a], reason: :last_alive}}
    outcome = Results.build("match", "instance", game, %{a: "Alice"})
    assert outcome.duration_ms == 10_000
    assert outcome.winner_ids == ["a"]
    assert outcome.final_scores == %{"a" => 0, "b" => 0}
    assert outcome.player_names == %{"a" => "Alice", "b" => nil}
  end

  test "the leaderboard refreshes when a persisted result is broadcast" do
    {:ok, view, _html} = live(build_conn(), "/leaderboard")

    assert {:ok, :inserted} =
             Results.record(result("live-board", %{"new-player" => 5}, ["new-player"]))

    Phoenix.PubSub.broadcast(
      Arena.PubSub,
      Leaderboard.topic(),
      {:leaderboard_updated, "live-board"}
    )

    assert :ok = await_html(view, "Name-new-player")
  end

  test "a slow database write does not block another match's tick and updates the LiveView" do
    await_pending()
    subscribe_telemetry()
    :ok = Phoenix.PubSub.subscribe(Arena.PubSub, Leaderboard.topic())
    id = start_match(["slow-a", "slow-b"])
    other = start_match(["other-a", "other-b"])

    Repo.query!("""
    CREATE FUNCTION arena_test_slow_result() RETURNS trigger AS $$
    BEGIN IF NEW.guest_id = 'slow-a' THEN PERFORM pg_sleep(1.5); END IF; RETURN NEW; END;
    $$ LANGUAGE plpgsql
    """)

    Repo.query!(
      "CREATE TRIGGER arena_test_slow BEFORE INSERT ON players FOR EACH ROW EXECUTE FUNCTION arena_test_slow_result()"
    )

    {:ok, _view, html} = live(build_conn(), "/leaderboard")
    refute html =~ "Guest-slow-a"
    assert {:ok, _} = Match.attach(id, "slow-a", self(), "Slow Player")
    assert :ok = Match.leave(id, "slow-b")
    {finish_us, :ok} = :timer.tc(fn -> Match.tick(id) end)
    assert finish_us < 1_000_000
    assert_receive {[:arena, :result_writer, :start], ^id}, 5_000
    refute_receive {:leaderboard_updated, ^id}, 100
    {elapsed_us, :ok} = :timer.tc(fn -> Match.tick(other) end)

    pending_during_tick =
      Enum.any?(MatchStore.pending_results(), fn {_key, result} -> result.match_id == id end)

    assert pending_during_tick
    assert elapsed_us < 1_000_000
    assert Match.snapshot(other).game.tick == 1
    assert_receive {:leaderboard_updated, ^id}, 5_000
    {:ok, _view, html} = live(build_conn(), "/leaderboard")
    assert html =~ "Slow Player"
    assert Repo.get!(Player, "slow-a").display_name == "Slow Player"
    assert Repo.get_by!(MatchResult, match_id: id).winner_ids == ["slow-a"]
  end

  test "a failing transaction retries without delaying ticks, then succeeds" do
    await_pending()
    subscribe_telemetry()
    :ok = Phoenix.PubSub.subscribe(Arena.PubSub, Leaderboard.topic())
    id = start_match(["retry-a", "retry-b"])
    other = start_match(["live-a", "live-b"])

    Repo.query!("""
    CREATE FUNCTION arena_test_fail_result() RETURNS trigger AS $$
    BEGIN IF NEW.guest_id = 'retry-a' THEN RAISE EXCEPTION 'temporary test failure'; END IF; RETURN NEW; END;
    $$ LANGUAGE plpgsql
    """)

    Repo.query!(
      "CREATE TRIGGER arena_test_fail BEFORE INSERT ON players FOR EACH ROW EXECUTE FUNCTION arena_test_fail_result()"
    )

    assert :ok = Match.leave(id, "retry-b")
    assert :ok = Match.tick(id)
    assert_receive {[:arena, :result_writer, :retry], ^id}, 5_000

    assert Enum.any?(MatchStore.pending_results(), fn {_pending_id, pending} ->
             pending.match_id == id
           end)

    refute Repo.get_by(MatchResult, match_id: id)
    {elapsed_us, :ok} = :timer.tc(fn -> Match.tick(other) end)
    assert elapsed_us < 1_000_000
    assert Match.snapshot(other).game.tick == 1
    Repo.query!("DROP TRIGGER arena_test_fail ON players")
    assert_receive {:leaderboard_updated, ^id}, 8_000
    assert Repo.get_by!(MatchResult, match_id: id).winner_ids == ["retry-a"]
    assert Repo.one(from s in PlayerStat, where: s.player_id == "retry-a", select: s.wins) == 1
  end
end
