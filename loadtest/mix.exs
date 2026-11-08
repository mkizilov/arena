defmodule ArenaLoad.MixProject do
  use Mix.Project

  def project do
    [app: :arena_load, version: "0.1.0", elixir: "~> 1.17", deps: deps()]
  end

  def application do
    [mod: {ArenaLoad.Application, []}, extra_applications: [:logger, :inets, :ssl]]
  end

  defp deps, do: [{:slipstream, "== 1.3.0"}, {:jason, "~> 1.4"}]
end
