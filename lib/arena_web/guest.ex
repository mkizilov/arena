defmodule ArenaWeb.Guest do
  @moduledoc "Creates and verifies signed, expiring guest identities."

  @salt "guest identity"
  @max_age 30 * 24 * 60 * 60

  def issue do
    id = :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)
    name = "Guest-" <> binary_part(id, 0, 6)
    guest = %{id: id, name: name}
    {guest, Phoenix.Token.sign(ArenaWeb.Endpoint, @salt, guest)}
  end

  def verify(token) when is_binary(token) do
    case Phoenix.Token.verify(ArenaWeb.Endpoint, @salt, token, max_age: @max_age) do
      {:ok, %{id: id, name: name} = guest}
      when is_binary(id) and byte_size(id) == 22 and is_binary(name) and byte_size(name) <= 32 ->
        {:ok, guest}

      _ ->
        {:error, :invalid_token}
    end
  end

  def verify(_), do: {:error, :invalid_token}
end
