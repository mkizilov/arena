defmodule ArenaWeb.HealthController do
  @moduledoc false
  use Phoenix.Controller, formats: [:json]

  def live(conn, _params), do: json(conn, %{status: "ok"})

  def ready(conn, _params) do
    checks = Arena.Health.check()
    status = if Arena.Health.ready?(checks), do: :ok, else: :service_unavailable

    conn
    |> Plug.Conn.put_resp_header("cache-control", "no-store")
    |> Plug.Conn.put_status(status)
    |> json(%{status: if(status == :ok, do: "ready", else: "not_ready"), checks: checks})
  end
end
