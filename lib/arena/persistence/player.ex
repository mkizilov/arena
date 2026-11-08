defmodule Arena.Persistence.Player do
  @moduledoc "A guest identity participating in a completed match."
  use Ecto.Schema

  @primary_key {:guest_id, :string, autogenerate: false}
  schema "players" do
    field :display_name, :string
    timestamps(type: :utc_datetime, updated_at: false)
  end
end
