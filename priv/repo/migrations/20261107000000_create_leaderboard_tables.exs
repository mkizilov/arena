defmodule Arena.Repo.Migrations.CreateLeaderboardTables do
  use Ecto.Migration

  def change do
    create table(:players, primary_key: false) do
      add :guest_id, :string, primary_key: true
      add :display_name, :string, null: false
      timestamps(type: :utc_datetime, updated_at: false)
    end

    create table(:match_results, primary_key: false) do
      add :result_id, :string, primary_key: true
      add :match_id, :string, null: false
      add :duration_ms, :integer, null: false
      add :winner_ids, {:array, :string}, null: false
      add :reason, :string, null: false
      add :final_scores, :map, null: false
      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:match_results, [:match_id])

    create table(:player_stats, primary_key: false) do
      add :player_id, references(:players, column: :guest_id, type: :string, on_delete: :delete_all), primary_key: true
      add :wins, :integer, null: false, default: 0
      add :best_score, :integer, null: false, default: 0
      add :matches_played, :integer, null: false, default: 0
      timestamps(type: :utc_datetime)
    end

    create index(:player_stats, [:wins])
    create index(:player_stats, [:best_score])
  end
end
