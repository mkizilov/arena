defmodule ArenaWeb.MatchChannel do
  @moduledoc false
  use Phoenix.Channel

  require Logger
  alias Arena.Match
  alias ArenaWeb.{GameJSON, Guest}

  @directions %{"up" => :up, "down" => :down, "left" => :left, "right" => :right}

  @impl true
  def join("match:" <> id, _payload, socket) when byte_size(id) > 0 do
    Logger.metadata(match_id: id)

    case Guest.verify(socket.assigns[:guest_token]) do
      {:ok, guest} ->
        Logger.metadata(player_id: guest.id)
        Arena.Telemetry.channel(:in, "join", id, guest.id)
        result = match_call(fn -> Match.attach(id, guest.id, self(), guest.name) end)
        Arena.Telemetry.channel(:out, "join_reply", id, guest.id)

        case result do
          {:ok, snapshot} ->
            send(self(), :after_join)
            socket = socket |> assign(:match_id, id) |> assign(:guest, guest)
            {:ok,
             %{
               player: guest,
               phase: snapshot.phase,
               countdown_ms: snapshot.countdown_ms,
               state: GameJSON.render(snapshot.game)
             }, socket}

          {:error, reason} -> {:error, %{reason: to_string(reason)}}
        end

      {:error, reason} ->
        Arena.Telemetry.channel(:in, "join", id, nil)
        Arena.Telemetry.channel(:out, "join_reply", id, nil)
        {:error, %{reason: to_string(reason)}}
    end
  end

  def join(topic, _payload, _socket) do
    id = String.replace_prefix(topic, "match:", "")
    Logger.metadata(match_id: id)
    Arena.Telemetry.channel(:in, "join", id, nil)
    Arena.Telemetry.channel(:out, "join_reply", id, nil)
    {:error, %{reason: "not_found"}}
  end

  @impl true
  def handle_in(event, payload, socket) do
    name = if event in ["ping", "resync", "input"], do: event, else: "other"
    Arena.Telemetry.channel(:in, name, socket.assigns.match_id, socket.assigns.guest.id)
    reply = handle_message(event, payload, socket)
    Arena.Telemetry.channel(:out, "reply", socket.assigns.match_id, socket.assigns.guest.id)
    {:reply, reply, socket}
  end

  defp handle_message("ping", _payload, _socket), do: :ok

  defp handle_message("resync", _payload, socket) do
    case match_call(fn -> Match.snapshot(socket.assigns.match_id) end) do
      {:ok, snapshot} ->
        {:ok, %{state: GameJSON.render(snapshot.game), phase: snapshot.phase, countdown_ms: snapshot.countdown_ms}}
      {:error, reason} -> {:error, %{reason: to_string(reason)}}
    end
  end

  defp handle_message("input", %{"direction" => direction}, socket) do
    case Map.fetch(@directions, direction) do
      {:ok, direction} ->
        result =
          match_call(fn ->
            Match.input(socket.assigns.match_id, socket.assigns.guest.id, direction)
          end)

        input_reply(result)

      :error ->
        {:error, %{reason: "invalid_direction"}}
    end
  end

  defp handle_message("input", _payload, _socket), do: {:error, %{reason: "invalid_direction"}}

  defp handle_message(_event, _payload, _socket), do: {:error, %{reason: "unsupported_event"}}

  @impl true
  def handle_info(:after_join, socket) do
    case match_call(fn -> Match.snapshot(socket.assigns.match_id) end) do
      {:ok, snapshot} ->
        push_message(socket, "status", %{
          phase: snapshot.phase,
          players: snapshot.players,
          countdown_ms: snapshot.countdown_ms
        })

        if snapshot.game do
          push_message(socket, "state", %{state: GameJSON.render(snapshot.game), events: []})
        end

      {:error, _} ->
        push_message(socket, "match_ended", %{reason: "unavailable"})
    end

    {:noreply, socket}
  end

  def handle_info({:match_status, id, phase, players}, %{assigns: %{match_id: id}} = socket) do
    countdown_ms =
      if phase == :countdown do
        case match_call(fn -> Match.snapshot(id) end) do
          {:ok, snapshot} -> snapshot.countdown_ms
          _ -> nil
        end
      end

    push_message(socket, "status", %{phase: phase, players: players, countdown_ms: countdown_ms})
    {:noreply, socket}
  end

  def handle_info({:match_ended_unexpectedly, id}, %{assigns: %{match_id: id}} = socket) do
    push_message(socket, "match_ended", %{reason: "unexpected"})
    {:stop, :normal, socket}
  end

  def handle_info({:match_recovering, id}, %{assigns: %{match_id: id}} = socket) do
    push_message(socket, "match_recovering", %{})
    {:noreply, socket}
  end

  def handle_info({:match_recovered, id, _pid}, %{assigns: %{match_id: id}} = socket) do
    push_message(socket, "match_recovered", %{})
    {:noreply, socket}
  end

  def handle_info({:match_disconnected, id, player}, %{assigns: %{match_id: id}} = socket) do
    push_message(socket, "player_disconnected", %{player: player})
    {:noreply, socket}
  end

  def handle_info({:match_reconnected, id, player}, %{assigns: %{match_id: id}} = socket) do
    push_message(socket, "player_reconnected", %{player: player})
    {:noreply, socket}
  end

  defp match_call(fun) do
    try do
      case fun.() do
        :ok -> :ok
        {:ok, snapshot} -> {:ok, snapshot}
        {:error, reason} -> {:error, reason}
        snapshot -> {:ok, snapshot}
      end
    catch
      :exit, {:noproc, _} -> {:error, :not_found}
      :exit, reason ->
        Logger.warning("match call failed: #{inspect(reason)}")
        {:error, :unavailable}
    end
  end

  defp input_reply(:ok), do: :ok
  defp input_reply({:error, reason}), do: {:error, %{reason: to_string(reason)}}

  defp push_message(socket, event, payload) do
    result = push(socket, event, payload)
    Arena.Telemetry.channel(:out, event, socket.assigns.match_id, socket.assigns.guest.id)
    result
  end
end
