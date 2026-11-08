defmodule Arena.Leaderboard do
  @moduledoc "Leaderboard rankings derived from completed match statistics."
  import Ecto.Query

  alias Arena.Persistence.{Player, PlayerStat}
  alias Arena.Repo

  def topic, do: "leaderboard"

  def top(:wins), do: ranked(desc: :wins, desc: :best_score, asc: :player_id)
  def top(:best_score), do: ranked(desc: :best_score, desc: :wins, asc: :player_id)

  defp ranked(order) do
    Repo.all(
      from stat in PlayerStat,
        join: player in Player,
        on: player.guest_id == stat.player_id,
        order_by: ^order,
        limit: 20,
        select: %{
          guest_id: player.guest_id,
          display_name: player.display_name,
          wins: stat.wins,
          best_score: stat.best_score,
          matches_played: stat.matches_played
        }
    )
  end
end
