defmodule ArenaWeb.ObservabilityPage do
  @moduledoc false
  use Phoenix.LiveDashboard.PageBuilder

  @impl true
  def menu_link(_session, _capabilities), do: {:ok, "Arena"}

  @impl true
  def mount(_params, _session, socket), do: {:ok, assign(socket, :arena, Arena.Observability.snapshot())}

  @impl true
  def handle_refresh(socket), do: {:noreply, assign(socket, :arena, Arena.Observability.snapshot())}

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <h2>Arena</h2>
      <dl>
        <dt>Active matches</dt><dd>{@arena.active_matches}</dd>
        <dt>Active players</dt><dd>{@arena.active_players}</dd>
        <dt>Ticks</dt><dd>{@arena.ticks}</dd>
        <dt>Tick overruns</dt><dd>{@arena.overruns}</dd>
        <dt>Last tick (µs)</dt><dd>{@arena.last_tick_us}</dd>
        <dt>Channel messages in</dt><dd>{@arena.messages_in}</dd>
        <dt>Channel messages out</dt><dd>{@arena.messages_out}</dd>
        <dt>Matchmaking waits</dt><dd>{@arena.waits}</dd>
        <dt>Total matchmaking wait (ms)</dt><dd>{@arena.wait_total_ms}</dd>
      </dl>
    </div>
    """
  end
end
