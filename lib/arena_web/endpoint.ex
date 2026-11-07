defmodule ArenaWeb.Endpoint do
  @moduledoc false
  use Phoenix.Endpoint, otp_app: :arena

  plug Plug.RequestId
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]
  plug Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    json_decoder: Phoenix.json_library()
  plug Plug.MethodOverride
  plug Plug.Head
  plug ArenaWeb.Router
end
