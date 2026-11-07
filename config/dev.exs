import Config

config :arena, Arena.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  port: 22301,
  database: "arena_dev",
  pool_size: 10

config :arena, ArenaWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 22300],
  secret_key_base: String.duplicate("development-only-secret-key-base-", 2),
  server: true

config :logger, :console, format: "[$level] $message\n"
