defmodule ArenaLoad.Bot do
  @moduledoc "A Slipstream bot using the same authenticated channel protocol as a client."
  use Slipstream, restart: :temporary

  alias ArenaLoad.Stats

  def start_link(opts), do: Slipstream.start_link(__MODULE__, opts)

  @impl Slipstream
  def init(opts) do
    number = Keyword.fetch!(opts, :number)
    token = Keyword.fetch!(opts, :token)
    port = Keyword.fetch!(opts, :port)
    stats = Keyword.fetch!(opts, :stats)
    query = URI.encode_query(%{"token" => token, "vsn" => "2.0.0"})
    uri = "ws://127.0.0.1:#{port}/socket/websocket?#{query}"
    rng = :rand.seed_s(:exsss, {number + 1, number + 13, number + 97})

    socket =
      new_socket()
      |> assign(%{
        stats: stats,
        player: Keyword.fetch!(opts, :player),
        rng: rng,
        topic: nil,
        direction: "right",
        alive: false,
        phase: "waiting",
        online: false,
        matched: false,
        queue_ref: nil
      })

    case connect(socket, uri: uri) do
      {:ok, socket} ->
        {:ok, socket, {:continue, :start}}

      {:error, reason} ->
        Stats.add(stats, :errors)
        {:stop, reason}
    end
  end

  @impl Slipstream
  def handle_continue(:start, socket) do
    Process.send_after(self(), :move, 250)
    {:noreply, socket}
  end

  @impl Slipstream
  def handle_connect(socket) do
    Stats.add(socket.assigns.stats, :connected)
    if not socket.assigns.online, do: Stats.add(socket.assigns.stats, :online)
    {:ok, socket |> assign(:online, true) |> join("lobby:queue")}
  end

  @impl Slipstream
  def handle_join("lobby:queue", _reply, socket) do
    Stats.add(socket.assigns.stats, :lobby_joins)
    {:ok, queue(socket)}
  end

  def handle_join("match:" <> _id, reply, socket) do
    Stats.add(socket.assigns.stats, :match_joins)
    if not socket.assigns.matched, do: Stats.add(socket.assigns.stats, :matched_bots)

    socket =
      socket
      |> assign(:matched, true)
      |> assign(:phase, reply["phase"])
      |> apply_snapshot(reply["state"])

    {:ok, socket}
  end

  @impl Slipstream
  def handle_message("lobby:queue", "match_found", %{"match_id" => id}, socket) do
    topic = "match:" <> id
    socket = socket |> assign(:topic, topic) |> assign(:alive, true)
    {:ok, join(socket, topic)}
  end

  def handle_message("lobby:queue", "queue_error", _payload, socket) do
    Stats.add(socket.assigns.stats, :errors)
    Process.send_after(self(), :queue, 1_000)
    {:ok, socket}
  end

  def handle_message(topic, "status", %{"phase" => phase}, socket) do
    if topic == socket.assigns.topic,
      do: {:ok, assign(socket, :phase, phase)},
      else: {:ok, socket}
  end

  def handle_message(topic, event, payload, socket) when event in ["state", "delta"] do
    if topic == socket.assigns.topic do
      socket = record_tick(socket, payload)

      socket =
        if event == "state",
          do: apply_snapshot(socket, payload["state"]),
          else: apply_delta(socket, payload)

      result =
        if event == "state", do: get_in(payload, ["state", "result"]), else: payload["result"]

      if result do
        socket = socket |> leave(topic) |> assign(:topic, nil) |> assign(:alive, false)
        Process.send_after(self(), :queue, 200)
        {:ok, socket}
      else
        {:ok, socket}
      end
    else
      {:ok, socket}
    end
  end

  def handle_message(_topic, _event, _payload, socket), do: {:ok, socket}

  @impl Slipstream
  def handle_reply(ref, reply, socket) do
    if ref == socket.assigns.queue_ref and reply not in [:ok] and not match?({:ok, _}, reply) do
      Stats.add(socket.assigns.stats, :errors)
      Process.send_after(self(), :queue, 1_000)
    end

    {:ok, socket}
  end

  @impl Slipstream
  def handle_info(:queue, socket), do: {:noreply, queue(socket)}

  def handle_info(:move, socket) do
    Process.send_after(self(), :move, 250)

    socket =
      if socket.assigns.topic && socket.assigns.alive && socket.assigns.phase == "running" do
        {direction, rng} = next_direction(socket.assigns.direction, socket.assigns.rng)

        case push(socket, socket.assigns.topic, "input", %{direction: direction}) do
          {:ok, _ref} -> Stats.add(socket.assigns.stats, :inputs)
          {:error, _} -> :ok
        end

        socket |> assign(:rng, rng) |> assign(:direction, direction)
      else
        socket
      end

    {:noreply, socket}
  end

  @impl Slipstream
  def handle_disconnect(_reason, socket) do
    Stats.add(socket.assigns.stats, :disconnects)
    if socket.assigns.online, do: Stats.add(socket.assigns.stats, :online, -1)
    socket = socket |> assign(:online, false) |> assign(:topic, nil) |> assign(:alive, false)

    case reconnect(socket) do
      {:ok, socket} -> {:ok, socket}
      {:error, reason} -> {:stop, reason, socket}
    end
  end

  @impl Slipstream
  def handle_topic_close("match:" <> _id, _reason, socket) do
    Stats.add(socket.assigns.stats, :errors)
    Process.send_after(self(), :queue, 1_000)
    {:ok, socket |> assign(:topic, nil) |> assign(:alive, false)}
  end

  def handle_topic_close(_topic, _reason, socket), do: {:stop, :lobby_closed, socket}

  @impl Slipstream
  def terminate(_reason, socket) do
    if socket.assigns.online, do: Stats.add(socket.assigns.stats, :online, -1)
    :ok
  end

  defp queue(socket) do
    case push(socket, "lobby:queue", "quick_play", %{}) do
      {:ok, ref} -> assign(socket, :queue_ref, ref)
      {:error, _} -> socket
    end
  end

  defp record_tick(socket, %{"server_tick_at_ms" => sent}) when is_integer(sent) do
    Stats.add(socket.assigns.stats, :ticks)
    Stats.latency(socket.assigns.stats, System.system_time(:millisecond) - sent)
    socket
  end

  defp record_tick(socket, _), do: socket

  defp apply_snapshot(socket, %{"snakes" => snakes}) do
    case Map.get(snakes, socket.assigns.player) do
      %{"direction" => direction, "alive" => alive} ->
        socket |> assign(:direction, direction) |> assign(:alive, alive)

      _ ->
        socket
    end
  end

  defp apply_snapshot(socket, _), do: socket

  defp apply_delta(socket, payload) do
    player = socket.assigns.player

    socket =
      case get_in(payload, ["moves", player, "direction"]) do
        nil -> socket
        direction -> assign(socket, :direction, direction)
      end

    if player in Map.get(payload, "deaths", []), do: assign(socket, :alive, false), else: socket
  end

  @doc false
  def next_direction(current, rng) do
    turns =
      if current in ["up", "down"], do: [current, "left", "right"], else: [current, "up", "down"]

    {choice, rng} = :rand.uniform_s(length(turns), rng)
    {Enum.at(turns, choice - 1), rng}
  end
end
