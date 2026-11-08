defmodule ArenaWeb.UserSocket do
  @moduledoc false
  use Phoenix.Socket, log: false

  channel "match:*", ArenaWeb.MatchChannel

  @impl true
  def connect(%{"token" => token}, socket, _connect_info) do
    case ArenaWeb.Guest.verify(token) do
      {:ok, guest} -> {:ok, socket |> assign(:guest, guest) |> assign(:guest_token, token)}
      {:error, _} -> :error
    end
  end

  def connect(_, _socket, _connect_info), do: :error

  @impl true
  def id(socket), do: "guest:#{socket.assigns.guest.id}"
end
