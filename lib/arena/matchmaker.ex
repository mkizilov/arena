defmodule Arena.Matchmaker do
  @moduledoc "The supervised entry point for creating matches; player matchmaking is not yet implemented."
  use GenServer

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @doc "Creates a match through the lobby."
  def start_match(id, opts \\ []), do: GenServer.call(__MODULE__, {:start_match, id, opts})

  @impl true
  def init(:ok), do: {:ok, nil}

  @impl true
  def handle_call({:start_match, id, opts}, _from, state) do
    {:reply, Arena.Match.start_match(id, opts), state}
  end
end
