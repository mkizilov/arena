defmodule Arena.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      Arena.PromEx,
      {Phoenix.PubSub, name: Arena.PubSub},
      {Registry, keys: :unique, name: Arena.MatchRegistry},
      Arena.MatchStore,
      {DynamicSupervisor, strategy: :one_for_one, name: Arena.MatchSupervisor, max_restarts: 1_000, max_seconds: 5},
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
