defmodule ArenaWeb.LobbyChannelTest do
  use ExUnit.Case, async: false
  import Phoenix.ChannelTest

  alias ArenaWeb.{Guest, LobbyChannel, UserSocket}

  @endpoint ArenaWeb.Endpoint

  test "eight authenticated channel clients join quick play and receive the same match" do
    Enum.each(1..8, fn _ ->
      {_guest, token} = Guest.issue()
      {:ok, socket} = connect(UserSocket, %{"token" => token})
      {:ok, _, channel} = subscribe_and_join(socket, LobbyChannel, "lobby:queue")
      ref = push(channel, "quick_play", %{})
      assert_reply ref, :ok
    end)

    assert_push "match_found", %{match_id: id}, 2_000
    on_exit(fn ->
      case Registry.lookup(Arena.MatchRegistry, id) do
        [{pid, _}] -> DynamicSupervisor.terminate_child(Arena.MatchSupervisor, pid)
        [] -> :ok
      end
    end)
    for _ <- 1..7, do: assert_push("match_found", %{match_id: ^id}, 2_000)
  end

  test "lobby channel validates the signed identity" do
    socket = socket(UserSocket, "guest", %{guest_token: "invalid"})
    assert {:error, %{reason: "invalid_token"}} = subscribe_and_join(socket, LobbyChannel, "lobby:queue")
  end

  test "a channel can cancel its own quick-play entry" do
    {guest, token} = Guest.issue()
    {:ok, socket} = connect(UserSocket, %{"token" => token})
    {:ok, _, channel} = subscribe_and_join(socket, LobbyChannel, "lobby:queue")
    ref = push(channel, "quick_play", %{})
    assert_reply ref, :ok
    assert guest.id in Arena.Matchmaker.queued()
    ref = push(channel, "cancel", %{})
    assert_reply ref, :ok
    refute guest.id in Arena.Matchmaker.queued()
  end
end
