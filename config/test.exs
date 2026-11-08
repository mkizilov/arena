import Config

config :arena, Arena.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  port: 22301,
  database: "arena_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 2

config :arena, ArenaWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 22302],
  secret_key_base: String.duplicate("test-only-secret-key-base-", 3),
  server: false

config :logger, level: :warning
config :arena, :cluster_strategy, :none
