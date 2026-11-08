defmodule ArenaWeb.Endpoint do
  @moduledoc false
  use Phoenix.Endpoint, otp_app: :arena

  @session_options [
    store: :cookie,
    key: "_arena_key",
    signing_salt: "arena_session",
    same_site: "Lax"
  ]

  socket "/socket", ArenaWeb.UserSocket, websocket: true, longpoll: false
  socket "/live", Phoenix.LiveView.Socket, websocket: [connect_info: [session: @session_options]]

  plug ArenaWeb.LocalObservability
  plug PromEx.Plug, prom_ex_module: Arena.PromEx
  plug Plug.Static, at: "/", from: :arena, only: ~w(guest.js)
  plug Plug.RequestId
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]

  plug Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    json_decoder: Phoenix.json_library()

  plug Plug.MethodOverride
  plug Plug.Head
  plug Plug.Session, @session_options
  plug ArenaWeb.Router
end
