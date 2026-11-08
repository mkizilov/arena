defmodule Arena.Release do
  @moduledoc "Database migrations for an assembled release."

  def migrate do
    Application.load(:arena)

    for repo <- Application.fetch_env!(:arena, :ecto_repos) do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end
  end
end
