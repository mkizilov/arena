# WebSocket load test

## Status and measured results

The requested production runs and profiling have **not been performed**. The execution environment has no Erlang/OTP, Elixir/Mix, or project-local PostgreSQL executable, and shell DNS cannot resolve Hex. It also prohibits use of the host Docker daemon. Consequently the Slipstream dependency could not be installed, the server and bots could not be started, and no real tick percentiles, overrun counts, CPU, match memory, message rates, bottleneck or before/after improvement can honestly be reported. The tool and server additions are unverified by Elixir compilation or an end-to-end WebSocket run here.

| Bots | Before: tick p50 / p99 | Overruns | CPU | Match memory | Messages/s | After |
| ---: | --- | --- | --- | --- | --- | --- |
| 100 | not run | not run | not run | not run | not run | not run |
| 1,000 | not run | not run | not run | not run | not run | not run |
| 5,000 | not run | not run | not run | not run | not run | not run |

No bottleneck has been identified or performance fix claimed: a profile and the requested before/after reruns are still required. The earlier synthetic frame-size calculation in `DESIGN.md` is not a load test.

## Tool

`loadtest/` is an independent Mix project pinned to Slipstream 1.3.0. Each bot obtains a real signed guest identity over HTTP, connects over a real Phoenix WebSocket, joins `lobby:queue`, requests quick play, joins its assigned match, and sends a seeded mixture of straight and perpendicular directions every 250 ms while alive and running. It rejoins quick play after a match ends. Bot counters and fixed latency buckets use bounded concurrent Erlang counters instead of collecting every sample in memory. The runner ramps clients, warms up, measures, emits JSON, and stops its own bot processes in an `after` block.

The server attaches `server_tick_at_ms` to each tick's broadcast at the start of simulation. Each bot records the difference from its own wall clock on arrival; this includes server processing, serialization, network and client scheduling. Run generator and server on the same host for a shared wall clock; negative samples are counted as invalid. This measures tick-start-to-arrival, not one-way network latency. The runner computes bot p50/p99 as latency bucket upper bounds, and server tick p50/p99 as Prometheus histogram bucket upper bounds from the difference between scrapes. Results are not exact quantiles. Counters are read while bots are active, so reads and interval boundaries are not atomic. Overruns and message counts are differences of node-local telemetry counters; output and tick fanout estimates retain the caveats in `DESIGN.md`.

The local-only `/loadtest/measurements` endpoint reports BEAM runtime, VM memory, OS PID, and the sum/count of `Process.info(pid, :memory)` for live match children. Mean match memory is that sum divided by count; it excludes shared binaries, ETS, socket/channel processes, the database and VM overhead. `ps` samples the server process's OS `%CPU` once per second; its mean is platform-dependent and can exceed 100% on multicore systems. BEAM runtime percentage is also reported separately. Instrumentation and same-host bots affect the server, so disclose machine, OS, scheduler settings, baseline activity, warmup, sample period, and client resource usage when interpreting results.

The runner only connects to `127.0.0.1` on ports 22300–22399 and rejects a server that is not a production build. It reports actual started and online counts, how many bots have joined at least one match, missing/reset metrics, invalid clocks and errors; an incomplete run exits nonzero after printing its report rather than claiming the requested load. A valid run requires every requested bot to have joined a match before measurement and to be online at both endpoints, plus tick, CPU and match-memory samples. The connection ramp stops after ten consecutive provisioning failures, and online counts reflect bot connection callbacks rather than an independent server census. If the server fails during sampling, the run exits with an error instead of a report. OS file-descriptor or process limits may prevent 5,000 clients; do not change host settings to hide that constraint. No credentials or datasets are written by the runner itself. Slipstream is pinned, but no dependency lockfile could be generated without Hex access.

## Reproduction in an authorized project-local environment

1. Install the pinned OTP/Elixir toolchain and dependencies inside this repository. Provision a **new, dedicated** PostgreSQL database named `arena_loadtest_12` on loopback port 22301; do not use a database with user data. Do not use a host Docker socket in this sandbox. The existing Compose file is reproducible outside the sandbox where Docker access is authorized.
2. Set `DATABASE_URL` to that database, set a newly generated `SECRET_KEY_BASE` in the shell environment, and run `MIX_ENV=prod mix deps.get`, `MIX_ENV=prod mix ecto.create`, and `MIX_ENV=prod mix ecto.migrate`. Start the production server on loopback port 22300, for example with `PHX_SERVER=1 PORT=22300 MIX_ENV=prod iex -S mix phx.server`. Do not store or commit the secret.
3. In `loadtest/`, run `MIX_ENV=prod mix deps.get` and `mix test --max-cases 2`. Then run each command below; use a fixed duration and warmup for baseline and after-change runs:

   ```sh
   MIX_ENV=prod mix arena.load --bots 100 --warmup 20 --duration 60 --ramp-ms 2
   MIX_ENV=prod mix arena.load --bots 1000 --warmup 20 --duration 60 --ramp-ms 2
   MIX_ENV=prod mix arena.load --bots 5000 --warmup 20 --duration 60 --ramp-ms 2
   ```

   Record the actual JSON, elapsed time, failed/online client counts, and any invalid/missing metrics. Let matches settle or restart the server between runs. Run only this workload against the dedicated database; quick play is a shared queue and otherwise may pair bots with real users.
4. During a representative steady run, profile **at most two** match processes for a bounded three seconds in the server's IEx session:

   ```elixir
   pids = Arena.MatchSupervisor |> Horde.DynamicSupervisor.which_children() |> Enum.flat_map(fn {_, pid, _, _} -> if is_pid(pid) and node(pid) == node(), do: [pid], else: [] end) |> Enum.take(2)
   if pids == [], do: raise("no active matches to profile")
   :eprof.start()
   :eprof.start_profiling(pids)
   Process.sleep(3_000)
   :eprof.stop_profiling()
   :eprof.analyze(:total)
   :eprof.stop()
   ```

   Record the actual profile and identify the dominant cost before modifying code. Apply a measured fix, rerun all three identical workloads and update the table with the real comparison. A two-process profile is a sample, not proof of a VM-wide bottleneck.
5. Stop the server and bots. After verifying that `DATABASE_URL` still names only the dedicated `arena_loadtest_12` database created for this run, from the repository root run `MIX_ENV=prod mix ecto.drop --force` with that same `DATABASE_URL` and `SECRET_KEY_BASE`. Remove only temporary run outputs created for the experiment; preserve source, user data and the supplied local environment. Never drop or delete an existing database or PostgreSQL data directory belonging to another task.
