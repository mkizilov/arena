defmodule Arena.ClusterTest do
  use ExUnit.Case, async: false
  require LocalCluster

  alias Arena.Match

  @tag timeout: 120_000
  test "three nodes distribute matches and resume them after a node stops" do
    unless Node.alive?() and System.get_env("ERL_EPMD_PORT") == "22351" do
      flunk(
        "start this test in a loopback-only distributed VM with ERL_EPMD_PORT=22351; see DESIGN.md"
      )
    end

    peers = for _ <- 1..2, do: start_peer()
    nodes = Enum.map(peers, &elem(&1, 1))

    Enum.each(nodes, fn n ->
      Enum.each(nodes -- [n], fn other -> :erpc.call(n, Node, :connect, [other]) end)
    end)

    eventually(fn ->
      length(Horde.Cluster.members(Arena.MatchSupervisor)) == 3 and
        length(Horde.Cluster.members(Arena.MatchRegistry)) == 3
    end)

    ids =
      for _ <- 1..18 do
        id = "cluster-#{System.unique_integer([:positive, :monotonic])}"

        {:ok, _pid} =
          Match.start_match(id, players: [:a, :b], seed: {1, 2, 3}, countdown_ms: 0, manual: true)

        on_exit(fn ->
          try do
            if Horde.Registry.lookup(Arena.MatchRegistry, id) != [], do: Match.stop(id)
          catch
            :exit, _ -> :ok
          end
        end)

        id
      end

    Enum.each(ids, fn id ->
      eventually(fn ->
        try do
          Match.snapshot(id).phase == :running
        catch
          :exit, _ -> false
        end
      end)

      for _ <- 1..3, do: assert(:ok = Match.tick(id))
    end)

    placements =
      Map.new(ids, fn id ->
        [{pid, _}] = Horde.Registry.lookup(Arena.MatchRegistry, id)
        {id, {pid, Match.snapshot(id).game}}
      end)

    assert placements
           |> Map.values()
           |> Enum.map(fn {pid, _} -> node(pid) end)
           |> Enum.uniq()
           |> length() >= 2

    victim =
      Enum.find(nodes, fn n -> Enum.any?(placements, fn {_id, {pid, _}} -> node(pid) == n end) end)

    assert victim
    affected = Enum.filter(placements, fn {_id, {pid, _}} -> node(pid) == victim end)
    assert affected != []

    Enum.each(affected, fn {id, {_pid, game}} ->
      saved = :erpc.call(victim, Arena.MatchStore, :get, [id])
      assert {:ok, %{result_id: instance}} = saved

      assert Enum.any?([node() | nodes] -- [victim], fn n ->
               match?({:ok, %{state: %{game: ^game}}}, Arena.MatchReplica.get(n, id, instance))
             end)
    end)

    {peer, ^victim} = Enum.find(peers, fn {_peer, n} -> n == victim end)
    monitor = Process.monitor(peer)
    :ok = :erpc.cast(victim, :erlang, :halt, [])
    assert_receive {:DOWN, ^monitor, :process, ^peer, _}, 5_000

    Enum.each(affected, fn {id, {_old, game}} ->
      assert_recovered(id, game, victim, [node() | nodes] -- [victim])

      assert :ok = Match.tick(id)
      assert Match.snapshot(id).game.tick == game.tick + 1
    end)
  end

  defp assert_recovered(id, game, victim, survivors) do
    eventually(fn ->
      case Horde.Registry.lookup(Arena.MatchRegistry, id) do
        [{pid, _}] when node(pid) != victim ->
          try do
            Match.snapshot(id).game == game
          catch
            :exit, _ -> false
          end

        _ ->
          false
      end
    end)
  rescue
    error in ExUnit.AssertionError ->
      details = Map.new(survivors, &{&1, recovery_diagnostics(&1, id)})

      flunk(
        "recovery of #{id} failed: #{Exception.message(error)}; survivors=#{inspect(details)}"
      )
  end

  defp recovery_diagnostics(target, id) do
    crdt =
      :erpc.call(target, DeltaCrdt, :to_map, [:"Elixir.Arena.MatchSupervisor.Crdt", 1_000], 1_500)

    children =
      for {{:process, _}, {owner, %{start: {Match, :start_link, [{^id, _}]}}, pid}} <- crdt,
          do: {owner, pid}

    %{
      connected: :erpc.call(target, Node, :list, [], 1_500),
      registry: :erpc.call(target, Horde.Registry, :lookup, [Arena.MatchRegistry, id], 1_500),
      supervisors: :erpc.call(target, Horde.Cluster, :members, [Arena.MatchSupervisor], 1_500),
      child_specs: children
    }
  rescue
    error -> %{error: Exception.message(error)}
  catch
    :exit, reason -> %{error: inspect(reason)}
  end

  defp start_peer do
    name = :"arena_peer_#{System.unique_integer([:positive, :monotonic])}"
    cookie = Node.get_cookie() |> Atom.to_charlist()

    args = [
      ~c"+S",
      ~c"1:1",
      ~c"-setcookie",
      cookie,
      ~c"-kernel",
      ~c"inet_dist_use_interface",
      ~c"{127,0,0,1}",
      ~c"inet_dist_listen_min",
      ~c"22352",
      ~c"inet_dist_listen_max",
      ~c"22359"
    ]

    {:ok, peer, node} =
      :peer.start_link(%{
        name: name,
        host: ~c"127.0.0.1",
        longnames: true,
        connection: :standard_io,
        args: args
      })

    Process.unlink(peer)

    on_exit(fn ->
      if Process.alive?(peer) do
        try do
          LocalCluster.stop_member(LocalCluster.member(pid: peer, node: node))
        catch
          :exit, _ -> :ok
        end
      end
    end)

    assert Node.connect(node)
    :ok = :erpc.call(node, :code, :add_paths, [:code.get_path()])
    :erpc.call(node, Application, :load, [:arena])

    for app <- [:arena, :phoenix, :logger, :prom_ex],
        {key, value} <- Application.get_all_env(app) do
      :erpc.call(node, Application, :put_env, [app, key, value])
    end

    {:ok, _} = :erpc.call(node, Application, :ensure_all_started, [:arena], 30_000)
    {peer, node}
  end

  defp eventually(fun, attempts \\ 200)
  defp eventually(_fun, 0), do: flunk("cluster did not converge before the deadline")

  defp eventually(fun, attempts) do
    if fun.(),
      do: :ok,
      else:
        (
          Process.sleep(50)
          eventually(fun, attempts - 1)
        )
  end
end
