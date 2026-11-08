defmodule Arena.PromEx do
  @moduledoc false
  use PromEx, otp_app: :arena

  @impl true
  def plugins, do: [Arena.PromEx.Game]
end

defmodule Arena.PromEx.Game do
  @moduledoc false
  use PromEx.Plugin

  @impl true
  def event_metrics(_opts), do: Event.build(:arena_game_metrics, Arena.Metrics.metrics())
end
