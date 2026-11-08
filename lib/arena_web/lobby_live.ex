defmodule ArenaWeb.LobbyLive do
  @moduledoc false
  use Phoenix.LiveView, layout: false

  alias Arena.{Lobby, Match, Matchmaker}
  alias ArenaWeb.Guest

  @impl true
  def mount(_params, _session, socket) do
    guest =
      if connected?(socket) do
        Phoenix.PubSub.subscribe(Arena.PubSub, Lobby.topic())

        params = get_connect_params(socket) || %{}

        case Guest.verify(params["guest_token"]) do
          {:ok, guest} -> guest
          {:error, _} -> nil
        end
      end

    {:ok,
     assign(socket,
       guest: guest,
       identity_ready: connected?(socket),
       matches: Lobby.open_matches(),
       queued: false,
       error: nil
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <main>
      <h1>Arena lobby</h1>
      <p :if={@guest}>Playing as {@guest.name}</p>
      <p :if={!@guest && !@identity_ready}>Connecting guest identity…</p>
      <p :if={!@guest && @identity_ready} role="alert">Guest identity unavailable. Reload to retry.</p>
      <p :if={@error} role="alert">{@error}</p>
      <button phx-click="quick_play" disabled={!@guest || @queued}>Quick play</button>
      <button :if={@queued} phx-click="cancel">Cancel queue</button>
      <span :if={@queued}>Waiting for players…</span>
      <section>
        <h2>Private room</h2>
        <button phx-click="create_private" disabled={!@guest}>Create private room</button>
        <form phx-submit="join_private">
          <label>Room code <input name="code" maxlength="8" required /></label>
          <button disabled={!@guest}>Join room</button>
        </form>
      </section>
      <section>
        <h2>Open matches</h2>
        <p :if={@matches == []}>No open matches yet.</p>
        <ul>
          <li :for={match <- @matches}>
            {match.id}: {match.player_count}/{match.capacity}
            <button phx-click="join_open" phx-value-id={match.id} disabled={!@guest}>Join</button>
          </li>
        </ul>
      </section>
    </main>
    """
  end

  @impl true
  def handle_event(_event, _params, %{assigns: %{guest: nil}} = socket),
    do: {:noreply, assign(socket, error: "Guest identity unavailable. Reload to retry.")}

  def handle_event("quick_play", _params, socket) do
    case Matchmaker.quick_play(socket.assigns.guest.id) do
      :ok -> {:noreply, assign(socket, queued: true, error: nil)}
      {:error, reason} -> {:noreply, assign(socket, error: message(reason))}
    end
  end

  def handle_event("cancel", _params, socket) do
    Matchmaker.cancel(socket.assigns.guest.id)
    {:noreply, assign(socket, queued: false)}
  end

  def handle_event("create_private", _params, socket) do
    socket = cancel_queue(socket)

    case Matchmaker.create_private(socket.assigns.guest.id) do
      {:ok, code} -> {:noreply, push_navigate(socket, to: "/matches/room-#{code}")}
      {:error, reason} -> {:noreply, assign(socket, error: message(reason))}
    end
  end

  def handle_event("join_private", %{"code" => code}, socket) when is_binary(code) do
    socket = cancel_queue(socket)

    case Matchmaker.join_private(code, socket.assigns.guest.id) do
      :ok -> {:noreply, push_navigate(socket, to: "/matches/room-#{String.upcase(code)}")}
      {:error, reason} -> {:noreply, assign(socket, error: message(reason))}
    end
  end

  def handle_event("join_open", %{"id" => id}, socket) when is_binary(id) do
    socket = cancel_queue(socket)

    result =
      if Enum.any?(Lobby.open_matches(), &(&1.id == id)) do
        try do
          Match.join(id, socket.assigns.guest.id)
        catch
          :exit, _ -> {:error, :not_found}
        end
      else
        {:error, :not_found}
      end

    case result do
      :ok -> {:noreply, push_navigate(socket, to: "/matches/#{URI.encode(id)}")}
      {:error, reason} -> {:noreply, assign(socket, error: message(reason))}
    end
  end

  def handle_event(_, _, socket), do: {:noreply, assign(socket, error: "Invalid request")}

  @impl true
  def handle_info({:lobby_updated, matches}, socket), do: {:noreply, assign(socket, matches: matches)}

  def handle_info({:match_found, id, player}, %{assigns: %{guest: %{id: player}}} = socket) do
    {:noreply, push_navigate(socket, to: "/matches/#{URI.encode(id)}")}
  end

  def handle_info({:matchmaking_error, _player, reason}, socket),
    do: {:noreply, assign(socket, error: message(reason))}

  defp cancel_queue(%{assigns: %{queued: true, guest: guest}} = socket) do
    Matchmaker.cancel(guest.id)
    assign(socket, queued: false)
  end

  defp cancel_queue(socket), do: socket

  defp message(:already_queued), do: "Already in the quick-play queue."
  defp message(:not_found), do: "Match or room not found."
  defp message(:full), do: "This match is full."
  defp message(:started), do: "This match has already started."
  defp message(_), do: "Unable to join a match. Please try again."
end
