# Arena

Phoenix application foundation for a server-authoritative multiplayer snake game. The pure simulation, supervised matches, quick-play queue, private rooms, lobby, signed guest identity and match channel protocol are described in [DESIGN.md](DESIGN.md).

## Local setup

Install the versions in `.tool-versions` with a project-local version manager, then install Hex and fetch dependencies with `mix local.hex` and `mix deps.get`. Start PostgreSQL with `docker compose up -d postgres` (data is stored in `.data/postgres`), run `mix ecto.setup`, then start the app with `mix phx.server`. The development endpoint is `http://127.0.0.1:22300/`; PostgreSQL listens on `127.0.0.1:22301`. Development database credentials are local-only and must not be used in production.

Run `mix check` for compilation, tests, formatting, Credo and Dialyzer; the test alias creates and migrates its own database. Dialyzer PLTs are stored in `priv/plts/`. Stop PostgreSQL with `docker compose down` when finished.

Visit `http://127.0.0.1:22300/lobby` for quick play, private rooms, and the open match list. The match page renders the board on a canvas; arrow keys and WASD send directions. The client stores a signed guest token in local storage. The earlier diagnostic page remains at `/play`. Run the browser module tests with `node --test --test-concurrency=2 test/js/*.test.*`.

Completed matches are written asynchronously to PostgreSQL, and `/leaderboard` shows wins and best scores. Migrate the database with `mix ecto.setup` before using persistence. Retries use a node-local in-memory outbox and do not survive a VM restart; see [DESIGN.md](DESIGN.md).

Local observability is available at `/dashboard/arena` and Prometheus metrics at `/metrics`. Both endpoints are restricted to loopback connections; a reverse proxy must also restrict access. See [DESIGN.md](DESIGN.md) for event definitions and measurement limitations.

The separate `loadtest/` Mix project contains Slipstream WebSocket bots. [LOADTEST.md](LOADTEST.md) describes its bounded loopback-only protocol, measurement method and the currently unverified production runs.

Game modules live in `assets/js/game/` and are embedded into the application at compile time; edits trigger recompilation. The browser receives Phoenix and LiveView's prebuilt ES modules from their installed dependencies, so no Node package installation or separate asset build is required. `floki` is a test-only dependency for LiveView tests.

Match updates use deltas with periodic full snapshots and gap recovery; the reproducible synthetic bandwidth comparison is in [DESIGN.md](DESIGN.md).

Match processes checkpoint to ETS and replicate checkpoints to another connected node when available; Horde places and recovers them across the cluster. Disconnected players have a ten-second reconnection grace period. Cluster setup, the checkpoint limitations, and test prerequisites are documented in [DESIGN.md](DESIGN.md).

Match state has explicit upgrade versions; the power-up rule, manual remote-console demonstration, and its limitations are documented in [UPGRADES.md](UPGRADES.md).

Production requires `DATABASE_URL` and `SECRET_KEY_BASE`; set `PHX_SERVER` to start the HTTP endpoint and `PHX_HOST` to its public hostname. TLS termination is expected upstream.

## Scaffold provenance

The shell environment used for this initial stage had neither Erlang nor Elixir and could not resolve GitHub or Hex. Consequently the requested `mix phx.new arena --no-mailer` generator could not be run. This is a manually written minimal Phoenix/Ecto foundation, not generator output; dependency resolution, formatting, compilation and runtime behavior must be verified in an environment with the pinned toolchain and package access.
