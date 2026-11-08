defmodule ArenaWeb.MatchChannelTest do
  use ExUnit.Case, async: true
  import Phoenix.ChannelTest

  alias Arena.Match
  alias ArenaWeb.{Guest, MatchChannel, UserSocket}

  @endpoint ArenaWeb.Endpoint

  defp start_match(opts \\ []) do
    id = "channel-#{System.unique_integer([:positive, :monotonic])}"
    :ok = Phoenix.PubSub.subscribe(Arena.PubSub, Match.topic(id))
    {:ok, _pid} = Match.start_match(id, opts)

    on_exit(fn ->
      case Horde.Registry.lookup(Arena.MatchRegistry, id) do
        [{_, _}] -> Match.stop(id)
        [] -> :ok
      end
    end)

    id
  end

  defp guest_socket do
    {guest, token} = Guest.issue()
    {:ok, socket} = connect(UserSocket, %{"token" => token})
    {guest, socket}
  end

  test "a signed guest joins and is added to the match" do
    id = start_match(countdown_ms: 60_000)
    {guest, socket} = guest_socket()

    assert {:ok, %{player: ^guest, phase: :waiting}, _socket} =
             subscribe_and_join(socket, MatchChannel, "match:" <> id)

    assert guest.id in Match.snapshot(id).players
  end

  test "invalid tokens are rejected on connection and on channel join" do
    assert :error = connect(UserSocket, %{"token" => "invalid"})
    assert :error = connect(UserSocket, %{})
    id = start_match()
    {_guest, socket} = guest_socket()
    socket = %{socket | assigns: Map.put(socket.assigns, :guest_token, "invalid")}

    assert {:error, %{reason: "invalid_token"}} =
             subscribe_and_join(socket, MatchChannel, "match:" <> id)
  end

  test "a new guest cannot join a full or finished match" do
    full = start_match(players: Enum.map(1..8, &"player-#{&1}"), countdown_ms: 60_000)
    {_guest, socket} = guest_socket()

    assert {:error, %{reason: "full"}} =
             subscribe_and_join(socket, MatchChannel, "match:" <> full)

    {guest, socket} = guest_socket()
    finished = start_match(players: [guest.id, "other"], countdown_ms: 0, manual: true)
    assert_receive {:match_status, ^finished, :running, _}
    assert :ok = Match.leave(finished, "other")
    assert :ok = Match.tick(finished)

    assert {:error, %{reason: "finished"}} =
             subscribe_and_join(socket, MatchChannel, "match:" <> finished)
  end

  test "input is forwarded and each tick is pushed as a JSON-safe state" do
    {guest, socket} = guest_socket()
    id = start_match(players: [guest.id, "other"], countdown_ms: 0, manual: true)
    assert_receive {:match_status, ^id, :running, _}

    assert {:ok, %{player: ^guest}, channel} =
             subscribe_and_join(socket, MatchChannel, "match:" <> id)

    ref = push(channel, "input", %{"direction" => "up"})
    assert_reply ref, :ok
    assert :ok = Match.tick(id)
    assert_push "state", %{state: %{tick: 1, snakes: snakes}, events: events}
    assert hd(snakes[guest.id].body) == [5, 3]
    assert {:ok, _json} = Jason.encode(%{snakes: snakes, events: events})

    assert :ok = Match.tick(id)
    assert_push "delta", %{tick: 2, moves: moves}
    assert moves[guest.id].head == [5, 2]
    ref = push(channel, "resync", %{})
    assert_reply ref, :ok, %{state: %{tick: 2}}

    ref = push(channel, "input", %{"direction" => "north"})
    assert_reply ref, :error, %{reason: "invalid_direction"}

    ref = push(channel, "ping", %{})
    assert_reply ref, :ok
  end

  test "a crashed match restores the connected channel with a full snapshot" do
    {guest, socket} = guest_socket()
    id = start_match(players: [guest.id, "other"], countdown_ms: 0, manual: true)
    assert_receive {:match_status, ^id, :running, _}
    assert {:ok, _, _channel} = subscribe_and_join(socket, MatchChannel, "match:" <> id)
    assert :ok = Match.tick(id)
    assert_push "state", %{state: %{tick: 1}}
    [{pid, _}] = Horde.Registry.lookup(Arena.MatchRegistry, id)
    Process.exit(pid, :kill)
    assert_push "match_recovered", %{}, 1_000
    assert_push "state", %{state: %{tick: 1}}, 1_000
  end
end
