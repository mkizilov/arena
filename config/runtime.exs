import Config

if config_env() == :prod do
  database_url = System.fetch_env!("DATABASE_URL")
  secret_key_base = System.fetch_env!("SECRET_KEY_BASE")

  config :arena, Arena.Repo, url: database_url, pool_size: 10

  config :arena, ArenaWeb.Endpoint,
    url: [host: System.get_env("PHX_HOST", "localhost"), port: 443, scheme: "https"],
    http: [ip: {127, 0, 0, 1}, port: String.to_integer(System.get_env("PORT", "22300"))],
    secret_key_base: secret_key_base,
    server: System.get_env("PHX_SERVER") != nil
end
