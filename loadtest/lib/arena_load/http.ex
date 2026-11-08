defmodule ArenaLoad.HTTP do
  @moduledoc false

  def get(port, path) do
    url = ~c"http://127.0.0.1:#{port}#{path}"

    case :httpc.request(:get, {url, []}, [timeout: 10_000, connect_timeout: 5_000], [body_format: :binary]) do
      {:ok, {{_, 200, _}, _headers, body}} -> {:ok, body}
      {:ok, {{_, status, _}, _headers, _body}} -> {:error, {:http_status, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  def json(port, path) do
    with {:ok, body} <- get(port, path), do: Jason.decode(body)
  end
end
