defmodule Arena.Repo do
  @moduledoc false
  use Ecto.Repo, otp_app: :arena, adapter: Ecto.Adapters.Postgres
end
