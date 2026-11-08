defmodule Arena.Persistence.MatchResult do
  @moduledoc "The immutable outcome of a completed match."
  use Ecto.Schema

  @primary_key {:result_id, :string, autogenerate: false}
  schema "match_results" do
    field :match_id, :string
    field :duration_ms, :integer
    field :winner_ids, {:array, :string}
    field :reason, :string
    field :final_scores, :map
    timestamps(type: :utc_datetime, updated_at: false)
  end
end
