import Config

if config_env() == :prod do
  database_url = System.fetch_env!("DATABASE_URL")
  secret_key_base = System.fetch_env!("SECRET_KEY_BASE")
  http_ip = if System.get_env("ARENA_CONTAINER_HTTP") == "1", do: {0, 0, 0, 0}, else: {127, 0, 0, 1}
  expected = System.get_env("ARENA_CLUSTER_EXPECTED_NODES", "1")
  expected_nodes = case Integer.parse(expected) do
    {count, ""} when count in 1..64 -> count
    _ -> raise "ARENA_CLUSTER_EXPECTED_NODES must be an integer from 1 to 64"
  end
  pool_size = case Integer.parse(System.get_env("POOL_SIZE", "10")) do
    {count, ""} when count in 1..100 -> count
    _ -> raise "POOL_SIZE must be an integer from 1 to 100"
  end

  config :arena, :expected_cluster_nodes, expected_nodes
  config :arena, Arena.Repo, url: database_url, pool_size: pool_size

  config :arena, ArenaWeb.Endpoint,
    url: [host: System.get_env("PHX_HOST", "localhost"), port: 443, scheme: "https"],
    http: [ip: http_ip, port: String.to_integer(System.get_env("PORT", "22300"))],
    secret_key_base: secret_key_base,
    server: System.get_env("PHX_SERVER") != nil

  if System.get_env("ARENA_CONTAINER_HTTP") == "1" do
    config :arena, ArenaWeb.Endpoint,
      url: [host: "127.0.0.1", port: 22300, scheme: "http"],
      check_origin: ["http://127.0.0.1:22300", "http://127.0.0.1:22302", "http://127.0.0.1:22303"]
  end
end
