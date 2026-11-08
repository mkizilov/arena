defmodule Arena.MatchReplicaTest do
  use ExUnit.Case, async: true

  alias Arena.{MatchReplica, MatchStore}

  test "replicas retain the newest sequence and can restore a lost local checkpoint" do
    id = "replica-#{System.unique_integer([:positive, :monotonic])}"
    instance = "instance-#{id}"

    on_exit(fn ->
      MatchStore.delete(id)
      MatchStore.abort_prepare(id, instance)
    end)

    assert :ok = MatchStore.prepare(id, instance)
    newer = %{seq: 7, state: %{result_id: instance, game: :newest}, result: nil}
    older = %{seq: 6, state: %{result_id: instance, game: :stale}, result: nil}
    assert :ok = MatchReplica.put(node(), id, instance, newer)
    assert {:error, :stale} = MatchReplica.put(node(), id, instance, older)
    assert {:ok, ^newer} = MatchReplica.get(node(), id, instance)
    assert {:ok, %{game: :newest}} = MatchStore.get(id, instance)
    assert :ok = MatchStore.delete(id)
    assert :deleted = MatchReplica.get(node(), id, instance)
    assert {:error, :deleted} = MatchReplica.put(node(), id, instance, newer)
    assert :deleted = MatchReplica.get(node(), id, instance)
    assert :deleted = MatchStore.get(id, instance)
  end

  test "different match instances sharing an ID do not reuse a stale snapshot" do
    id = "replica-#{System.unique_integer([:positive, :monotonic])}"

    on_exit(fn ->
      MatchStore.abort_prepare(id, "new")
      MatchReplica.delete(node(), id, "old")
    end)

    assert :ok =
             MatchReplica.put(node(), id, "old", %{
               seq: 9,
               state: %{result_id: "old"},
               result: nil
             })

    assert :ok = MatchStore.prepare(id, "new")
    assert :new = MatchStore.get(id, "new")
    assert :ok = MatchStore.abort_prepare(id, "new")
    assert :ok = MatchReplica.delete(node(), id, "old")
  end
end
