defmodule ArenaLoad.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    Supervisor.start_link(
      [{DynamicSupervisor, name: ArenaLoad.BotSupervisor, strategy: :one_for_one}],
      strategy: :one_for_one,
      name: ArenaLoad.Supervisor
    )
  end
end
