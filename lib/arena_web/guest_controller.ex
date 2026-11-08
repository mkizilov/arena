defmodule ArenaWeb.GuestController do
  @moduledoc false
  use Phoenix.Controller, formats: [:html, :json]

  alias ArenaWeb.Guest

  def show(conn, _params) do
    {guest, token} = identity(conn)

    conn
    |> Plug.Conn.put_resp_header("cache-control", "no-store")
    |> json(%{id: guest.id, name: guest.name, token: token})
  end

  def play(conn, _params) do
    conn
    |> Plug.Conn.put_resp_content_type("text/html")
    |> Plug.Conn.send_resp(200, """
    <!doctype html>
    <html lang="en"><head><meta charset="utf-8"><title>Arena guest</title></head>
    <body><h1>Arena</h1><p id="identity">Connecting…</p>
    <form id="join"><label>Match ID <input id="match" required></label><button>Join</button></form>
    <p>Use arrow keys to change direction.</p><pre id="state"></pre>
    <script src="/guest.js" defer></script></body></html>
    """)
  end

  defp identity(conn) do
    case Plug.Conn.get_req_header(conn, "authorization") do
      ["Bearer " <> token] ->
        case Guest.verify(token) do
          {:ok, guest} -> {guest, token}
          {:error, _} -> Guest.issue()
        end

      _ ->
        Guest.issue()
    end
  end
end
