defmodule Arena.Health do
  @moduledoc "Readiness checks for the database and converged cluster membership."
  require Logger

  def check do
    %{database: database_ready?(), cluster: cluster_ready?()}
  end

  def ready?(%{database: database, cluster: cluster}), do: database and cluster

  def database_ready? do
    case Ecto.Adapters.SQL.query(Arena.Repo, "SELECT 1", [], timeout: 1_000, queue_timeout: 1_000) do
      {:ok, %{rows: [[1]]}} -> true
      {:error, _reason} -> false
    end
  rescue
    error ->
      Logger.warning("readiness database check failed: #{Exception.message(error)}")
      false
  catch
    :exit, reason ->
      Logger.warning("readiness database check exited: #{inspect(reason)}")
      false
  end

  def cluster_ready? do
    expected = Application.get_env(:arena, :expected_cluster_nodes, 1)
    connected = [node() | Node.list()]
    registry = Horde.Cluster.members(Arena.MatchRegistry)
    supervisor = Horde.Cluster.members(Arena.MatchSupervisor)
    cluster_ready?(node(), connected, registry, supervisor, expected)
  rescue
    error ->
      Logger.warning("readiness cluster check failed: #{Exception.message(error)}")
      false
  catch
    :exit, reason ->
      Logger.warning("readiness cluster check exited: #{inspect(reason)}")
      false
  end

  @doc "Checks connected nodes shared by both Horde membership views."
  def cluster_ready?(current, connected, registry, supervisor, expected) do
    connected = MapSet.new(connected)
    registry = MapSet.new(registry, &member_node(&1, Arena.MatchRegistry, current))
    supervisor = MapSet.new(supervisor, &member_node(&1, Arena.MatchSupervisor, current))
    common = connected |> MapSet.intersection(registry) |> MapSet.intersection(supervisor)
    MapSet.member?(common, current) and MapSet.size(common) >= expected
  end

  defp member_node({name, member}, expected, _current) when name == expected and is_atom(member), do: member
  defp member_node(name, expected, current) when name == expected and is_atom(name), do: current
  defp member_node(_, _name, _current), do: nil
end
