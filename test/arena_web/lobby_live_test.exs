defmodule ArenaWeb.LobbyLiveTest do
  use ExUnit.Case, async: false
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Arena.{Lobby, Match, Matchmaker}
  alias ArenaWeb.Guest

  @endpoint ArenaWeb.Endpoint

  defp guest_conn do
    {guest, token} = Guest.issue()
    {guest, put_connect_params(build_conn(), %{"guest_token" => token})}
  end

  defp cleanup_match(id) do
    on_exit(fn ->
      case Horde.Registry.lookup(Arena.MatchRegistry, id) do
        [{_, _}] -> Match.stop(id)
        [] -> :ok
      end
    end)
  end

  test "a signed guest can enter and cancel quick play" do
    {guest, conn} = guest_conn()
    {:ok, view, html} = live(conn, "/lobby")
    assert html =~ guest.name
    assert render_click(view, "quick_play") =~ "Waiting for players"
    assert guest.id in Matchmaker.queued()
    refute render_click(view, "cancel") =~ "Waiting for players"
    refute guest.id in Matchmaker.queued()
  end

  test "creates and joins a private room through the lobby" do
    {host, conn} = guest_conn()
    {:ok, view, _html} = live(conn, "/lobby")
    assert {:error, {:live_redirect, %{to: "/matches/room-" <> code}}} =
             render_click(view, "create_private")

    id = "room-" <> code
    cleanup_match(id)
    assert Match.snapshot(id).players == [host.id]
    {guest, other_conn} = guest_conn()
    {:ok, other, _html} = live(other_conn, "/lobby")
    assert {:error, {:live_redirect, %{to: "/matches/room-" <> ^code}}} =
             render_submit(other, "join_private", %{"code" => String.downcase(code)})

    assert Match.snapshot(id).players == [host.id, guest.id]
    refute Enum.any?(Lobby.open_matches(), &(&1.id == id))
  end

  test "lists public open matches and renders the canvas match page" do
    id = "live-#{System.unique_integer([:positive, :monotonic])}"
    {:ok, _pid} = Match.start_match(id, countdown_ms: 60_000)
    cleanup_match(id)
    {guest, conn} = guest_conn()
    {:ok, view, html} = live(conn, "/lobby")
    assert html =~ id
    assert html =~ "0/8"
    assert {:error, {:live_redirect, %{to: "/matches/" <> ^id}}} =
             render_click(view, "join_open", %{"id" => id})

    assert guest.id in Match.snapshot(id).players
    {_guest, conn} = guest_conn()
    {:ok, _view, html} = live(conn, "/matches/#{id}")
    assert html =~ "phx-hook=\"Game\""
    assert html =~ "<canvas"
  end
end
