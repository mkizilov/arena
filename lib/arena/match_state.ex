defmodule Arena.MatchState do
  @moduledoc "Sequential, pure migrations for match-process checkpoint state."

  alias Arena.Game

  @current_version 2
  def current_version, do: @current_version

  @doc "Upgrades an unversioned or older match state to the current version."
  def upgrade(state) when is_map(state) do
    case Map.get(state, :version, 0) do
      0 -> state |> Map.put(:version, 1) |> upgrade()
      1 -> upgrade_one(state)
      @current_version -> {:ok, state}
      version -> {:error, {:unsupported_match_state_version, version}}
    end
  end

  def upgrade(_), do: {:error, :invalid_match_state}

  defp upgrade_one(state) do
    with {:ok, game} <- Map.fetch(state, :game),
         {:ok, published} <- Map.fetch(state, :published_game),
         {:ok, game} <- migrate_game(game),
         {:ok, published} <- normalize_game(published) do
      {:ok,
       state
       |> Map.put(:game, game)
       |> Map.put(:published_game, published)
       |> Map.put(:version, 2)}
    else
      :error -> {:error, :invalid_match_state}
      {:error, reason} -> {:error, reason}
    end
  end

  defp migrate_game(game) do
    with {:ok, game} <- normalize_game(game) do
      if game do
        {game, _} = Game.enable_power_up(game)
        {:ok, game}
      else
        {:ok, nil}
      end
    end
  end

  defp normalize_game(nil), do: {:ok, nil}
  defp normalize_game(%Game{} = game), do: {:ok, Map.put_new(game, :power_up, nil)}
  defp normalize_game(_), do: {:error, :invalid_game_state}
end
