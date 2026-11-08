defmodule Arena.Results do
  @moduledoc "Builds and transactionally records idempotent match outcomes."

  alias Arena.Persistence.{MatchResult, Player}
  alias Arena.Repo
  alias Ecto.Adapters.SQL

  def build(id, result_id, game, names) do
    scores = Map.new(game.snakes, fn {player, snake} -> {to_string(player), snake.score} end)

    names =
      Map.new(game.snakes, fn {player, _snake} ->
        key = to_string(player)
        {key, Map.get(names, player)}
      end)

    %{
      match_id: id,
      result_id: result_id,
      duration_ms: div(game.tick * 1_000, 15),
      winner_ids: Enum.map(game.result.winners, &to_string/1),
      reason: to_string(game.result.reason),
      final_scores: scores,
      player_names: names
    }
  end

  def record(result) do
    Repo.transaction(fn ->
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      result.final_scores
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.each(&upsert_player(&1, result.player_names, now))

      row = result |> Map.delete(:player_names) |> Map.put(:inserted_at, now)

      {inserted, _} =
        Repo.insert_all(MatchResult, [row], on_conflict: :nothing, conflict_target: [:result_id])

      if inserted == 1 do
        record_stats(result)
        :inserted
      else
        :duplicate
      end
    end)
  end

  defp upsert_player({id, _score}, names, now) do
    name = Map.get(names, id)
    display_name = name || "Guest-" <> String.slice(id, 0, 6)
    conflict = if name, do: [set: [display_name: name]], else: :nothing

    Repo.insert_all(Player, [%{guest_id: id, display_name: display_name, inserted_at: now}],
      on_conflict: conflict,
      conflict_target: [:guest_id]
    )
  end

  defp record_stats(result) do
    result.final_scores
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.each(fn {id, score} -> update_stats(id, score, id in result.winner_ids) end)
  end

  defp update_stats(id, score, winner) do
    SQL.query!(
      Repo,
      """
      INSERT INTO player_stats (player_id, wins, best_score, matches_played, inserted_at, updated_at)
      VALUES ($1, $2, $3, 1, timezone('UTC', now()), timezone('UTC', now()))
      ON CONFLICT (player_id) DO UPDATE SET
        wins = player_stats.wins + EXCLUDED.wins,
        best_score = GREATEST(player_stats.best_score, EXCLUDED.best_score),
        matches_played = player_stats.matches_played + 1,
        updated_at = EXCLUDED.updated_at
      """,
      [id, if(winner, do: 1, else: 0), score]
    )
  end
end
