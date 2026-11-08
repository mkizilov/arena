defmodule Arena.Cluster do
  @moduledoc "Local gossip and Compose DNS discovery configuration."

  def topologies do
    strategy =
      Application.get_env(:arena, :cluster_strategy) ||
        System.get_env("ARENA_CLUSTER_STRATEGY", if(Node.alive?(), do: "gossip", else: "none"))

    case strategy do
      :none ->
        []

      "none" ->
        []

      "gossip" ->
        [
          local: [
            strategy: Cluster.Strategy.Gossip,
            config: [
              port: 22_350,
              if_addr: {127, 0, 0, 1},
              multicast_if: {127, 0, 0, 1},
              multicast_addr: {239, 255, 42, 42},
              multicast_ttl: 1,
              secret: System.get_env("ARENA_GOSSIP_SECRET")
            ]
          ]
        ]

      "dns" ->
        [
          compose: [
            strategy: Cluster.Strategy.DNSPoll,
            config: [
              query: System.get_env("ARENA_CLUSTER_DNS", "arena-node"),
              node_basename: System.get_env("ARENA_NODE_BASENAME", "arena"),
              polling_interval: 5_000
            ]
          ]
        ]

      other ->
        raise ArgumentError, "invalid cluster strategy: #{inspect(other)}"
    end
  end

  def alive?(pid) when is_pid(pid) and node(pid) == node(), do: Process.alive?(pid)

  def alive?(pid) when is_pid(pid) do
    :erpc.call(node(pid), Process, :alive?, [pid], 1_000)
  catch
    :error, _ -> false
    :exit, _ -> false
  end

  def alive?(_), do: false
end
