defmodule ArenaWeb.AssetController do
  @moduledoc false
  use Phoenix.Controller

  for file <- ~w(app.mjs hook.mjs render.mjs) do
    path = Path.expand("../../assets/js/game/#{file}", __DIR__)
    @external_resource path
    defp game_source(unquote(file)), do: unquote(File.read!(path))
  end

  defp game_source(_), do: nil

  def game(conn, %{"file" => file}), do: respond(conn, game_source(file))

  def vendor(conn, %{"file" => "phoenix.mjs"}) do
    respond(conn, File.read!(Application.app_dir(:phoenix, "priv/static/phoenix.mjs")))
  end

  def vendor(conn, %{"file" => "phoenix_live_view.esm.js"}) do
    respond(conn, File.read!(Application.app_dir(:phoenix_live_view, "priv/static/phoenix_live_view.esm.js")))
  end

  def vendor(conn, _params), do: respond(conn, nil)

  defp respond(conn, nil), do: Plug.Conn.send_resp(conn, 404, "Not found")

  defp respond(conn, body) do
    conn |> Plug.Conn.put_resp_content_type("text/javascript") |> Plug.Conn.send_resp(200, body)
  end
end
