defmodule Arena.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      Arena.PromEx,
      {Cluster.Supervisor, [Arena.Cluster.topologies(), [name: Arena.ClusterSupervisor]]},
      {Phoenix.PubSub, name: Arena.PubSub},
      {Horde.Registry, name: Arena.MatchRegistry, keys: :unique, members: :auto},
      Arena.MatchReplica,
      Arena.MatchStore,
      {Horde.DynamicSupervisor, strategy: :one_for_one, name: Arena.MatchSupervisor,
        members: :auto, process_redistribution: :passive, max_restarts: 1_000, max_seconds: 5},
      Arena.Observability,
      Arena.Lobby,
      Arena.Matchmaker,
      {Task.Supervisor, name: Arena.TaskSupervisor},
      Arena.ResultWriter,
      Arena.Repo,
      ArenaWeb.Endpoint
    ]

    Supervisor.start_link(children, strategy: :rest_for_one, name: Arena.Supervisor)
  end

  @impl true
  def config_change(changed, _new, removed) do
    ArenaWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
