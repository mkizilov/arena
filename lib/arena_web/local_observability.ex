defmodule ArenaWeb.LocalObservability do
  @moduledoc false
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    protected = conn.request_path == "/metrics" or conn.request_path == "/dashboard" or
      String.starts_with?(conn.request_path, "/dashboard/")

    if protected and not loopback?(conn.remote_ip) do
      conn |> send_resp(403, "Forbidden") |> halt()
    else
      conn
    end
  end

  defp loopback?({127, _, _, _}), do: true
  defp loopback?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  defp loopback?(_), do: false
end
