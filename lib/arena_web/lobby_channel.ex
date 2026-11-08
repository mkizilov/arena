defmodule ArenaWeb.LobbyChannel do
  @moduledoc "Authenticated quick-play transport for channel clients."
  use Phoenix.Channel
  require Logger

  alias Arena.Matchmaker
  alias ArenaWeb.Guest

  @impl true
  def join("lobby:queue", _payload, socket) do
    case Guest.verify(socket.assigns[:guest_token]) do
      {:ok, guest} ->
        Logger.metadata(player_id: guest.id)
        Arena.Telemetry.channel(:in, "lobby_join", nil, guest.id)
        Arena.Telemetry.channel(:out, "lobby_join_reply", nil, guest.id)
        {:ok, %{player: guest}, assign(socket, :guest, guest)}

      {:error, _} ->
        Arena.Telemetry.channel(:in, "lobby_join", nil, nil)
        Arena.Telemetry.channel(:out, "lobby_join_reply", nil, nil)
        {:error, %{reason: "invalid_token"}}
    end
  end

  @impl true
  def handle_in(event, _payload, socket) do
    guest = socket.assigns.guest
    name = if event in ["quick_play", "cancel"], do: event, else: "other"
    Arena.Telemetry.channel(:in, name, nil, guest.id)

    result = case event do
      "quick_play" -> Matchmaker.quick_play(guest.id)
      "cancel" -> Matchmaker.cancel(guest.id)
      _ -> {:error, :unsupported_event}
    end

    reply = case result do
      :ok -> :ok
      {:error, reason} -> {:error, %{reason: to_string(reason)}}
    end

    Arena.Telemetry.channel(:out, "lobby_reply", nil, guest.id)
    {:reply, reply, socket}
  end

  @impl true
  def handle_info({:match_found, id, player}, %{assigns: %{guest: %{id: player}}} = socket) do
    push(socket, "match_found", %{match_id: id})
    Arena.Telemetry.channel(:out, "match_found", id, player)
    {:noreply, socket}
  end

  def handle_info({:matchmaking_error, player, _reason}, %{assigns: %{guest: %{id: player}}} = socket) do
    push(socket, "queue_error", %{reason: "match_unavailable"})
    Arena.Telemetry.channel(:out, "queue_error", nil, player)
    {:noreply, socket}
  end
end
