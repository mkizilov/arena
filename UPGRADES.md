# Match state upgrades

## Status

The live release demonstration has **not been run** in this environment: Erlang/OTP, Elixir/Mix and PostgreSQL are unavailable, and shell DNS cannot resolve Hex. The tests in `test/arena/match_state_test.exs` include direct migrations and a simulated `:sys.change_code` on a running process, but they also remain unverified here. No live-upgrade result or timing is claimed.

## Version contract

Match process state now has `:version` 2. An absent version (or version 0) is the unversioned state from before this change. `Arena.MatchState.upgrade/1` explicitly moves 0 → 1 and then 1 → 2. Version 1 → 2 adds `:power_up` to the current and last-published game states and uses the current game's explicit RNG state to place one on an unoccupied cell; the last-published state remains without it so the next delta transmits the addition. Waiting matches have no game to migrate. Finished games do not spawn an item. Unknown versions and invalid states return errors; downgrades are deliberately unsupported. The migration is pure and deterministic.

`Arena.Match.code_change/3` invokes that migration. Restored ETS/replica checkpoints also pass through it, so a crash before the next post-upgrade tick does not restore the old shape into new code. The in-memory checkpoint is updated on the next tick or other state-changing operation, not synchronously inside `code_change/3`.

The new purple power-up awards five points without growing the snake. It is consumed only by a surviving snake; it respawns on a free cell distinct from food using the explicit RNG state, or stays absent if no cell is free. Food still awards one point and one segment. The server includes the item in full snapshots and deltas; refreshed clients render it.

## Isolated remote-console demonstration

This procedure is intended for an **isolated, single-node, disposable** project-local release and database, with no real users or other matches. It briefly suspends the match process; it is not a zero-pause upgrade. Do not run it in a multi-node cluster or against a shared database. The exact steps remain unverified until the required local toolchain is available.

1. Generate a `mix.lock` from the current source with `MIX_ENV=prod mix deps.get`. Export the pre-upgrade source from commit `c1def9a` into a new directory under `.agent-local/`, copy that same `mix.lock` into it, run `MIX_ENV=prod mix deps.get`, and build its release with `MIX_ENV=prod mix release`. For example, from the repository root, after confirming the destination is new:

   ```sh
   mkdir -p .agent-local/upgrade-v1-src
   git archive c1def9a | tar -x -C .agent-local/upgrade-v1-src
   cp mix.lock .agent-local/upgrade-v1-src/mix.lock
   ```

   In `.agent-local/upgrade-v1-src`, run the two Mix commands above. In the current repository, run `MIX_ENV=prod mix compile`. Compare the resolved dependency lockfiles and OTP/Elixir versions; abort if they differ. Both old and new code must target the same dependencies and OTP release. Do not overwrite an existing release or user files.
2. Create a **new dedicated** project-local PostgreSQL database for this demonstration and run its migrations. Set `DATABASE_URL`, a newly generated `SECRET_KEY_BASE`, and `PHX_SERVER=1`. Use a named local release node, a project-only `RELEASE_COOKIE`, `ERL_EPMD_ADDRESS=127.0.0.1`, `ERL_EPMD_PORT=22351`, loopback-only distribution ports 22352–22359, `PORT=22300`, and `ARENA_CLUSTER_STRATEGY=none`. Set `ARENA_UPGRADE_BEAM_DIR` in the **server's environment** to the absolute project-local `_build/prod/lib/arena/ebin` directory containing the newly compiled modules. Start the old release's `bin/arena start`, then connect with its `bin/arena remote` using the same release-node and cookie settings. Keep secrets in the environment, not committed files.
3. In the remote console, paste the following single block. It starts a real automatic-tick match, briefly suspends that same process, loads the new modules, invokes `code_change`, then resumes and checks both continued ticks and the rule. The controlled item placement is a **test fixture**, used so the rule is exercised immediately rather than waiting for a randomly placed item. Stop if any step fails; mixed old/new modules are not safe to leave running. Only this one match may exist while the modules are replaced.

   ```elixir
   id = "upgrade-demo"
   {:ok, pid} = Arena.Match.start_match(id, players: ["a", "b"], seed: {1, 2, 3}, countdown_ms: 0)
   ready = Enum.find(1..50, fn _ ->
     Process.sleep(10)
     Arena.Match.snapshot(id).phase == :running
   end)
   if is_nil(ready), do: raise("match did not start")
   before = Arena.Match.snapshot(id).game
   :ok = :sys.suspend(pid)

   try do
     dir = System.fetch_env!("ARENA_UPGRADE_BEAM_DIR")
     for mod <- [Arena.Game, ArenaWeb.GameJSON, ArenaWeb.AssetController, Arena.MatchState, Arena.Match] do
       path = Path.join(dir, Atom.to_string(mod)) |> String.to_charlist()
       {:module, ^mod} = :code.load_abs(path)
     end
     :ok = :sys.change_code(pid, Arena.Match, :unversioned, [])
     %{version: 2} = :sys.get_state(pid)

     :sys.replace_state(pid, fn state ->
       {{:value, {x, y}}, _} = :queue.out(state.game.snakes["a"].body)
       occupied = state.game.snakes |> Enum.flat_map(fn {_, s} -> :queue.to_list(s.body) end) |> MapSet.new()
       {cell, direction} = Enum.find([{{x, y - 1}, :up}, {{x, y + 1}, :down}], fn {cell, _} ->
         cell != state.game.food and not MapSet.member?(occupied, cell)
       end) || raise("no safe fixture cell")
       %{state | game: %{state.game | power_up: cell}, inputs: Map.put(state.inputs, "a", direction)}
     end)
   after
     :sys.resume(pid)
   end

   Process.sleep(150)
   after_game = Arena.Match.snapshot(id).game
   true = after_game.tick > before.tick
   true = after_game.snakes["a"].score >= before.snakes["a"].score + 5
   IO.inspect(%{before_tick: before.tick, after_tick: after_game.tick, score: after_game.snakes["a"].score})
   ```

   A long suspension may cause the existing scheduler to catch up immediately and end the match before the assertion; that is a failed demonstration, not evidence of success. A client can reload the match page to fetch the new embedded renderer. Check the actual tick and score output, and record it rather than substituting expected values.
4. Stop the release and any driver processes. After verifying that `DATABASE_URL` names only the disposable database created for this demonstration, drop that database with the native Ecto command. Remove only the isolated `.agent-local/upgrade-v1-src` and release outputs created for this experiment, and stop only a project-scoped EPMD instance you started after confirming no other nodes use it. Do not remove supplied environment files or another task's data.

## Limits and full release upgrades

Manually loading BEAM files is an operational probe, not a managed deployment: it has no atomic dependency graph, automatic rollback, supervised application transition, asset rollout, database migration ordering, or cluster-wide coordination. Suspending one match does not protect other processes executing old code; code loading permits at most two module versions and `:code.soft_purge/1` may fail while old code is still in use. Do not force-purge processes. This demo's fixture changes state solely to exercise a rule and is unsuitable for real matches. Replica state is volatile and mixed-version nodes can disagree about the state shape; upgrade an isolated node only unless a coordinated compatibility strategy has been tested.

Use a proper OTP release upgrade with reviewed `.appup` instructions and a generated `relup` when deploying compatible code and state transitions to a long-running release. Those artifacts define module load order and state transforms and can coordinate application supervision changes; they still require tested forward/backward compatibility, database and asset deployment plans, and a cluster rollout strategy. Use a restart or rolling deployment when that coordination is unavailable or an incompatible downgrade is needed. This project does not yet supply or test appups/relups.
