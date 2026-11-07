defmodule Arena.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children = [Arena.Repo, {Phoenix.PubSub, name: Arena.PubSub}, ArenaWeb.Endpoint]
    Supervisor.start_link(children, strategy: :one_for_one, name: Arena.Supervisor)
  end

  @impl true
  def config_change(changed, _new, removed) do
    ArenaWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
