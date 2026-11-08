defmodule ArenaWeb.MatchChannel do
  @moduledoc false
  use Phoenix.Channel

  require Logger
  alias Arena.Match
  alias ArenaWeb.{GameJSON, Guest}

  @directions %{"up" => :up, "down" => :down, "left" => :left, "right" => :right}

  @impl true
  def join("match:" <> id, _payload, socket) when byte_size(id) > 0 do
    with {:ok, guest} <- Guest.verify(socket.assigns[:guest_token]),
         {:ok, snapshot} <- match_call(fn -> Match.attach(id, guest.id, self(), guest.name) end) do
      send(self(), :after_join)
      socket = socket |> assign(:match_id, id) |> assign(:guest, guest)
      {:ok,
       %{
         player: guest,
         phase: snapshot.phase,
         countdown_ms: snapshot.countdown_ms,
         state: GameJSON.render(snapshot.game)
       }, socket}
    else
      {:error, reason} -> {:error, %{reason: to_string(reason)}}
    end
  end

  def join(_, _payload, _socket), do: {:error, %{reason: "not_found"}}

  @impl true
  def handle_in("ping", _payload, socket), do: {:reply, :ok, socket}

  def handle_in("resync", _payload, socket) do
    case match_call(fn -> Match.snapshot(socket.assigns.match_id) end) do
      {:ok, snapshot} ->
        {:reply, {:ok, %{state: GameJSON.render(snapshot.game), phase: snapshot.phase, countdown_ms: snapshot.countdown_ms}}, socket}
      {:error, reason} -> {:reply, {:error, %{reason: to_string(reason)}}, socket}
    end
  end

  def handle_in("input", %{"direction" => direction}, socket) do
    case Map.fetch(@directions, direction) do
      {:ok, direction} ->
        result =
          match_call(fn ->
            Match.input(socket.assigns.match_id, socket.assigns.guest.id, direction)
          end)

        {:reply, input_reply(result), socket}

      :error ->
        {:reply, {:error, %{reason: "invalid_direction"}}, socket}
    end
  end

  def handle_in("input", _payload, socket),
    do: {:reply, {:error, %{reason: "invalid_direction"}}, socket}

  def handle_in(_event, _payload, socket),
    do: {:reply, {:error, %{reason: "unsupported_event"}}, socket}

  @impl true
  def handle_info(:after_join, socket) do
    case match_call(fn -> Match.snapshot(socket.assigns.match_id) end) do
      {:ok, snapshot} ->
        push(socket, "status", %{
          phase: snapshot.phase,
          players: snapshot.players,
          countdown_ms: snapshot.countdown_ms
        })

        if snapshot.game do
          push(socket, "state", %{state: GameJSON.render(snapshot.game), events: []})
        end

      {:error, _} ->
        push(socket, "match_ended", %{reason: "unavailable"})
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

    push(socket, "status", %{phase: phase, players: players, countdown_ms: countdown_ms})
    {:noreply, socket}
  end

  def handle_info({:match_ended_unexpectedly, id}, %{assigns: %{match_id: id}} = socket) do
    push(socket, "match_ended", %{reason: "unexpected"})
    {:stop, :normal, socket}
  end

  def handle_info({:match_recovering, id}, %{assigns: %{match_id: id}} = socket) do
    push(socket, "match_recovering", %{})
    {:noreply, socket}
  end

  def handle_info({:match_recovered, id, _pid}, %{assigns: %{match_id: id}} = socket) do
    push(socket, "match_recovered", %{})
    {:noreply, socket}
  end

  def handle_info({:match_disconnected, id, player}, %{assigns: %{match_id: id}} = socket) do
    push(socket, "player_disconnected", %{player: player})
    {:noreply, socket}
  end

  def handle_info({:match_reconnected, id, player}, %{assigns: %{match_id: id}} = socket) do
    push(socket, "player_reconnected", %{player: player})
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
end
