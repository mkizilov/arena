defmodule ArenaWeb.LeaderboardLive do
  @moduledoc false
  use Phoenix.LiveView, layout: false
  require Logger

  alias Arena.Leaderboard

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(Arena.PubSub, Leaderboard.topic())
    {:ok, refresh(socket)}
  end

  @impl true
  def handle_info({:leaderboard_updated, _id}, socket), do: {:noreply, refresh(socket)}

  @impl true
  def render(assigns) do
    ~H"""
    <main>
      <h1>Leaderboard</h1>
      <a href="/lobby">Back to lobby</a>
      <p :if={@error} role="alert">Leaderboard unavailable. Please try again later.</p>
      <section>
        <h2>Most wins</h2>
        <ol id="top-wins">
          <li :for={player <- @wins}>
            {player.display_name}: {player.wins} wins (best {player.best_score})
          </li>
        </ol>
      </section>
      <section>
        <h2>Best score</h2>
        <ol id="top-scores">
          <li :for={player <- @scores}>
            {player.display_name}: {player.best_score} points ({player.wins} wins)
          </li>
        </ol>
      </section>
    </main>
    """
  end

  defp refresh(socket) do
    assign(socket,
      wins: Leaderboard.top(:wins),
      scores: Leaderboard.top(:best_score),
      error: false
    )
  rescue
    error ->
      Logger.warning("leaderboard unavailable: #{Exception.message(error)}")
      assign(socket, wins: [], scores: [], error: true)
  catch
    :exit, reason ->
      Logger.warning("leaderboard unavailable: #{inspect(reason)}")
      assign(socket, wins: [], scores: [], error: true)
  end
end
