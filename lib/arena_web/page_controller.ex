defmodule ArenaWeb.PageController do
  @moduledoc false
  use Phoenix.Controller, formats: [:json]

  def index(conn, _params), do: json(conn, %{application: "arena"})
end
