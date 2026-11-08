defmodule ArenaWeb.HealthControllerTest do
  use ExUnit.Case, async: false
  import Plug.Test

  alias Arena.{Health, Repo}
  alias Ecto.Adapters.SQL.Sandbox

  test "liveness is available without querying the database" do
    response = conn(:get, "/healthz") |> ArenaWeb.Endpoint.call([])
    assert response.status == 200
    assert Jason.decode!(response.resp_body) == %{"status" => "ok"}
  end

  test "readiness checks the sandbox database and local Horde membership" do
    owner = Sandbox.start_owner!(Repo, shared: true)
    on_exit(fn -> Sandbox.stop_owner(owner) end)
    response = conn(:get, "/readyz") |> ArenaWeb.Endpoint.call([])
    assert response.status == 200

    assert Jason.decode!(response.resp_body) == %{
             "status" => "ready",
             "checks" => %{"database" => true, "cluster" => true}
           }

    assert Plug.Conn.get_resp_header(response, "cache-control") == ["no-store"]
  end

  test "readiness requires connected members in both Horde views" do
    current = :"one@127.0.0.1"
    other = :"two@127.0.0.1"
    connected = [current, other]
    registry = [{Arena.MatchRegistry, current}, {Arena.MatchRegistry, other}]
    supervisor = [{Arena.MatchSupervisor, current}, {Arena.MatchSupervisor, other}]
    assert Health.cluster_ready?(current, connected, registry, supervisor, 2)
    refute Health.cluster_ready?(current, [current], registry, supervisor, 2)
    refute Health.cluster_ready?(current, connected, registry, [hd(supervisor)], 2)

    refute Health.cluster_ready?(
             current,
             connected,
             [{:wrong_registry, current}, {:wrong_registry, other}],
             supervisor,
             2
           )

    refute Health.ready?(%{database: false, cluster: true})
    refute Health.ready?(%{database: true, cluster: false})
    assert Health.ready?(%{database: true, cluster: true})
  end

  test "an unavailable sandbox connection makes the database check fail closed" do
    refute Health.database_ready?()
    refute Health.ready?(%{database: false, cluster: true})
  end
end
