import Config

config :arena, ecto_repos: [Arena.Repo]

config :arena, ArenaWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [formats: [json: ArenaWeb.ErrorJSON], layout: false],
  pubsub_server: Arena.PubSub,
  live_view: [signing_salt: "arena_dev"]

config :phoenix, :json_library, Jason

import_config "#{config_env()}.exs"
