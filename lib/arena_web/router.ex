defmodule ArenaWeb.Router do
  @moduledoc false
  use Phoenix.Router
  import Plug.Conn
  import Phoenix.Controller
  import Phoenix.LiveView.Router
  import Phoenix.LiveDashboard.Router

  pipeline :api do
    plug :accepts, ["json"]
  end

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {ArenaWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  scope "/", ArenaWeb do
    pipe_through :api
    get "/", PageController, :index
    get "/guest", GuestController, :show
  end

  scope "/", ArenaWeb do
    get "/play", GuestController, :play
    get "/assets/game/:file", AssetController, :game
    get "/assets/vendor/:file", AssetController, :vendor
  end

  scope "/", ArenaWeb do
    pipe_through :browser
    live "/lobby", LobbyLive
    live "/leaderboard", LeaderboardLive
    live "/matches/:id", MatchLive
  end

  scope "/" do
    pipe_through :browser
    live_dashboard "/dashboard", metrics: Arena.Metrics, additional_pages: [arena: ArenaWeb.ObservabilityPage]
  end
end
