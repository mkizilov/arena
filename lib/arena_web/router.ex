defmodule ArenaWeb.Router do
  @moduledoc false
  use Phoenix.Router

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", ArenaWeb do
    pipe_through :api
    get "/", PageController, :index
  end
end
