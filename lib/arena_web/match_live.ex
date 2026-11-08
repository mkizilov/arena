defmodule ArenaWeb.MatchLive do
  @moduledoc false
  use Phoenix.LiveView, layout: false

  @impl true
  def mount(%{"id" => id}, _session, socket), do: {:ok, assign(socket, id: id)}

  @impl true
  def render(assigns) do
    ~H"""
    <main>
      <h1>Match {@id}</h1>
      <p :if={String.starts_with?(@id, "room-")}>Room code: {String.replace_prefix(@id, "room-", "")}</p>
      <a href="/lobby">Back to lobby</a>
      <div id="match-game" phx-hook="Game" phx-update="ignore" data-match-id={@id}>
        <p data-status aria-live="polite">Connecting…</p>
        <p>Latency: <span data-latency>—</span></p>
        <canvas data-canvas width="800" height="600" aria-label="Snake game board"></canvas>
        <p>Move using arrow keys or WASD.</p>
        <h2>Scores</h2>
        <ul data-scores></ul>
        <p data-result role="status"></p>
      </div>
    </main>
    """
  end
end
