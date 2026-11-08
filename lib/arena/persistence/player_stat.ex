defmodule Arena.Persistence.PlayerStat do
  @moduledoc "Per-player aggregate statistics."
  use Ecto.Schema

  @primary_key {:player_id, :string, autogenerate: false}
  schema "player_stats" do
    field :wins, :integer, default: 0
    field :best_score, :integer, default: 0
    field :matches_played, :integer, default: 0
    timestamps(type: :utc_datetime)
  end
end
