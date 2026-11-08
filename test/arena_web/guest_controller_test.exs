defmodule ArenaWeb.GuestControllerTest do
  use ExUnit.Case, async: true
  import Plug.Test

  test "issues a guest token, preserves a valid identity, and replaces a bad token" do
    first = conn(:get, "/guest") |> ArenaWeb.Endpoint.call([])
    assert first.status == 200
    assert Plug.Conn.get_resp_header(first, "cache-control") == ["no-store"]
    guest = Jason.decode!(first.resp_body)
    assert %{"id" => id, "name" => "Guest-" <> _, "token" => token} = guest
    assert {:ok, %{id: ^id}} = ArenaWeb.Guest.verify(token)

    again =
      conn(:get, "/guest")
      |> Plug.Conn.put_req_header("authorization", "Bearer " <> token)
      |> ArenaWeb.Endpoint.call([])

    assert Jason.decode!(again.resp_body) == guest

    invalid =
      conn(:get, "/guest")
      |> Plug.Conn.put_req_header("authorization", "Bearer invalid")
      |> ArenaWeb.Endpoint.call([])

    refute Jason.decode!(invalid.resp_body)["id"] == id
  end

  test "the guest client is served from the play page" do
    page = conn(:get, "/play") |> ArenaWeb.Endpoint.call([])
    assert page.status == 200
    assert page.resp_body =~ "/guest.js"
    script = conn(:get, "/guest.js") |> ArenaWeb.Endpoint.call([])
    assert script.status == 200
    assert script.resp_body =~ "arena.guestToken"
  end

  test "game and framework modules are served as JavaScript with a whitelist" do
    for path <- [
          "/assets/game/app.mjs",
          "/assets/game/hook.mjs",
          "/assets/game/render.mjs",
          "/assets/game/delta.mjs",
          "/assets/vendor/phoenix.mjs",
          "/assets/vendor/phoenix_live_view.esm.js"
        ] do
      response = conn(:get, path) |> ArenaWeb.Endpoint.call([])
      assert response.status == 200

      assert Plug.Conn.get_resp_header(response, "content-type") == [
               "text/javascript; charset=utf-8"
             ]
    end

    assert (conn(:get, "/assets/game/other.mjs") |> ArenaWeb.Endpoint.call([])).status == 404
  end
end
