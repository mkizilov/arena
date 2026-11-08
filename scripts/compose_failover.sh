#!/bin/sh
set -eu

if [ "${1:-}" != "--confirm" ] || [ "$#" -ne 1 ]; then
  echo "Usage: $0 --confirm (kills app1 in the named project and then restores it)" >&2
  exit 2
fi

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
project=${ARENA_COMPOSE_PROJECT:-arena-prod}
case "$project" in
  ''|*[!a-z0-9_-]*) echo "Invalid Compose project name" >&2; exit 2 ;;
esac

compose() { docker compose -p "$project" -f "$root/docker-compose.prod.yml" "$@"; }
rpc() { service=$1; expression=$2; compose exec -T "$service" /app/bin/cluster-entrypoint rpc "$expression"; }

match_id=""
killed=0

cleanup() {
  status=$?
  if [ -n "$match_id" ]; then
    expression="case Horde.Registry.lookup(Arena.MatchRegistry, \"$match_id\") do [{pid, _}] -> :ok = GenServer.call(pid, :stop); IO.puts(\"ARENA_CLEANED\"); [] -> IO.puts(\"ARENA_ABSENT\") end"
    cleaned=0
    for service in app2 app1; do
      if output=$(rpc "$service" "$expression" 2>/dev/null); then
        if printf '%s\n' "$output" | awk '/^ARENA_CLEANED$/ {found=1} END {exit !found}'; then
          cleaned=1
          break
        fi
      fi
    done
    if [ "$cleaned" -ne 1 ]; then
      echo "Could not confirm cleanup of demo match $match_id; inspect the cluster." >&2
      status=1
    fi
  fi
  if [ "$killed" -eq 1 ]; then
    if ! compose up -d --no-deps app1 >/dev/null; then
      echo "Could not restore app1 in project $project; restart it manually." >&2
      status=1
    fi
  fi
  trap - EXIT
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP

for service in app1 app2 nginx; do
  [ -n "$(compose ps -q "$service")" ] || { echo "$service is not running in project $project" >&2; exit 1; }
done

base="failover-$(date +%s)-$$"
attempt=1
expected_hash=""
instance=""

while [ "$attempt" -le 40 ]; do
  candidate="$base-$attempt"
  expression="id = \"$candidate\"; {:ok, pid} = Arena.Match.start_match(id, players: [\"a\", \"b\"], seed: {1, 2, 3}, countdown_ms: 0, manual: true); try do if node(pid) == node() do ready = Enum.find(1..100, fn _ -> Process.sleep(20); GenServer.call(pid, :snapshot).phase == :running end); if is_nil(ready), do: raise(\"match did not start\"); Enum.each(1..3, fn _ -> :ok = GenServer.call(pid, :tick) end); state = :sys.get_state(pid); hash = :crypto.hash(:sha256, :erlang.term_to_binary(state.game, [:deterministic])) |> Base.encode16(case: :lower); IO.puts(\"ARENA_MATCH \" <> hash <> \" \" <> state.result_id) else :ok = GenServer.call(pid, :stop); IO.puts(\"ARENA_RETRY\") end rescue error -> GenServer.call(pid, :stop); reraise error, __STACKTRACE__ end"
  output=$(rpc app1 "$expression") || { echo "Could not confirm demo match $candidate; inspect the cluster for that ID" >&2; exit 1; }
  marker=$(printf '%s\n' "$output" | awk '/^ARENA_MATCH / {print $2 " " $3; exit}')
  if [ -n "$marker" ]; then
    match_id=$candidate
    expected_hash=${marker%% *}
    instance=${marker#* }
    break
  fi
  printf '%s\n' "$output" | awk '/^ARENA_RETRY$/ {found=1} END {exit !found}' || { echo "Unrecognized reply; inspect the cluster for $candidate" >&2; exit 1; }
  attempt=$((attempt + 1))
done

[ -n "$match_id" ] || { echo "Could not place a demo match on app1" >&2; exit 1; }
case "$expected_hash" in *[!0-9a-f]*|'') echo "Invalid match hash" >&2; exit 1 ;; esac
case "$instance" in *[!A-Za-z0-9_-]*|'') echo "Invalid match instance" >&2; exit 1 ;; esac
[ "${#expected_hash}" -eq 64 ] || { echo "Invalid match hash length" >&2; exit 1; }

backup="case Arena.MatchReplica.get(node(), \"$match_id\", \"$instance\") do {:ok, %{state: %{game: game}}} -> hash = :crypto.hash(:sha256, :erlang.term_to_binary(game, [:deterministic])) |> Base.encode16(case: :lower); if game.tick == 3 and hash == \"$expected_hash\", do: IO.puts(\"ARENA_BACKUP_OK\"), else: IO.puts(\"ARENA_WAIT\"); _ -> IO.puts(\"ARENA_WAIT\") end"
output=$(rpc app2 "$backup") || { echo "Could not inspect app2 replica" >&2; exit 1; }
printf '%s\n' "$output" | awk '/^ARENA_BACKUP_OK$/ {found=1} END {exit !found}' || { echo "Replica did not match tick 3; refusing to kill app1" >&2; exit 1; }

echo "Killing app1 with demo match $match_id at tick 3"
killed=1
compose kill -s KILL app1 >/dev/null

verify="case Horde.Registry.lookup(Arena.MatchRegistry, \"$match_id\") do [{pid, _}] when node(pid) == node() -> state = GenServer.call(pid, :snapshot); hash = :crypto.hash(:sha256, :erlang.term_to_binary(state.game, [:deterministic])) |> Base.encode16(case: :lower); if state.game.tick == 3 and hash == \"$expected_hash\" do :ok = GenServer.call(pid, :tick); next = GenServer.call(pid, :snapshot); if next.game.tick == 4, do: IO.puts(\"ARENA_RESUMED\"), else: IO.puts(\"ARENA_WAIT\") else IO.puts(\"ARENA_WAIT\") end; _ -> IO.puts(\"ARENA_WAIT\") end"
attempt=1
while [ "$attempt" -le 45 ]; do
  if output=$(rpc app2 "$verify" 2>/dev/null); then
    if printf '%s\n' "$output" | awk '/^ARENA_RESUMED$/ {found=1} END {exit !found}'; then
      if ! curl -fsS --max-time 5 http://127.0.0.1:22300/healthz >/dev/null; then
        echo "Match recovered but the loopback nginx liveness probe failed" >&2
        exit 1
      fi
      echo "Recovered identical tick 3 on app2 and advanced to tick 4"
      exit 0
    fi
  fi
  attempt=$((attempt + 1))
  sleep 1
done

echo "Failover did not recover demo match $match_id within 45 seconds" >&2
exit 1
