# Arena design

The pure game core, match process, guest identity, and match channels are implemented.

## Rules

Each match runs on a 40 × 30 grid with up to eight snakes. The server advances the simulation at 15 ticks per second. Snakes move one cell per tick, grow and score by eating food, and die on hitting a wall or any snake. The last snake alive wins; if the match reaches three minutes (2,700 ticks), the highest score wins. Simultaneous elimination and equal scores produce a tie. A match starts with at least two players. Food placement uses the match's explicit random seed; occupied cells are never chosen.

## Architecture

`Arena.Game` is a pure, deterministic state-transition core. Its inputs include the current state, player commands, and explicit random seed state; it performs no process operations, clock reads, or implicit random calls. A single `Arena.Match` GenServer per match owns the game state, gathers commands and schedules ticks. Phoenix Channels validate and translate transport messages, forward commands to the match, and relay server snapshots; they contain no game rules. The server is authoritative: clients never submit positions, scores, or outcomes as truth.

### Core contract

`Arena.Game.new(player_ids, {a, b, c})` requires two to eight unique IDs and creates three-cell, right-facing snakes in the input order, plus one seeded food cell. Coordinates are zero-based, with x increasing right and y increasing down. Bodies are Erlang queues ordered head first. `tick(state, inputs)` accepts a map of player IDs to direction atoms and returns `{state, events}`; absent, invalid, or opposite directions retain the current direction. Unrecognized player IDs are ignored.

All live snakes propose their moves simultaneously. A non-growing snake's tail vacates before collisions; a growing snake's tail remains. A head hitting a wall, any remaining body (including its own), another proposed head, or swapping head positions with another snake dies. Snakes killed on food do not eat or grow. Dead bodies do not block future ticks or food placement. Surviving eaters score one point and grow by one cell; one new food is selected uniformly from free cells using the explicit RNG state. If no cell is free, food remains absent. Events are `{:ate, player_id, cell}`, `{:died, player_id}`, `{:food_spawned, cell}`, and `{:match_over, %{winners: ids, reason: reason}}`, in player ID order followed by food and match events. Initial food is in the returned state, not an event.

If all snakes die on the same tick, the result has no winners and reason `:simultaneous_death`; otherwise a sole survivor wins immediately. On tick 2,700, if multiple snakes remain, the highest score among all participants wins, with all tied players included. Elimination takes precedence over the time limit. A finished game does not advance or emit further events.

### Match lifecycle and API

`Arena.Match.start_match(id, opts)` starts a transient child under `Arena.MatchSupervisor` registered by nonempty string ID in `Arena.MatchRegistry`. `join(id, player)` admits at most eight unique players; the second starts a three-second countdown, during which others may join. If fewer than two remain, the countdown is cancelled and the match returns to waiting. A waiting match is stopped after 60 seconds without a join or leave. Players cannot join once running. An explicit `leave` forfeits a running snake immediately, with a `:died` event on the next tick. A finished match is stopped after a ten-second grace period. Normal shutdowns are not restarted; abnormal match exits restart from the checkpoint.

`input(id, player, direction)` accepts a valid direction from a joined living player while running, retaining only the latest input until the next tick. `snapshot(id)` returns the current phase, ordered players and game state. A match runs at 15 ticks per second against deadlines derived from a monotonic epoch; if delayed, it catches up without skipping simulation ticks. `manual: true` disables automatic running ticks and allows `tick(id)` to advance exactly one tick. Options `:seed`, `:countdown_ms`, `:idle_ms`, and `:grace_ms` allow deterministic and bounded tests; a seed is generated at match creation if omitted. Countdown, idle and shutdown timers remain active in manual mode.

Subscribers to `Arena.Match.topic(id)` on `Arena.PubSub` receive `{:match_status, id, phase, players}` on membership or phase changes and a `Phoenix.Socket.Broadcast` for each tick (`state` or `delta`). The lobby publishes `{:match_recovering, id}` and `{:match_recovered, id, pid}` around an abnormal match restart; if recovery does not complete within five seconds it publishes `{:match_ended_unexpectedly, id}`. `Arena.Lobby.matches/0` lists live match process IDs (including finished matches during their grace period). Calls for an unknown or restarting match can fail; callers should handle that boundary.

### Crash recovery and disconnects

`Arena.MatchStore` owns a private ETS table independent of individual match processes. Matches synchronously save their game, RNG, buffered inputs, membership, connection PIDs, lifecycle, and monotonic deadlines before acknowledging relevant changes and before broadcasting each tick. The restart re-arms lifecycle and disconnect timers, re-monitors surviving sessions, publishes a full snapshot and status, and resumes from that checkpoint. A crash between checkpoint and broadcast is repaired by the recovery snapshot. A running match resets its scheduling epoch after recovery, so time spent restarting pauses simulation rather than producing a catch-up burst; simulation ticks and the three-minute tick limit do not advance during that pause. Normal match shutdown deletes its checkpoint.

The channel atomically attaches its process to the signed player ID. When the last session for a player dies, the match clears buffered input and starts a ten-second monotonic reconnect deadline; the snake continues in its current direction. A matching guest reconnecting before the deadline reclaims the same snake and cancels the timer. After expiry the player is removed and forfeits on the next tick; if the snake dies naturally before reconnecting it cannot be reclaimed. Multiple simultaneous sessions for one guest do not start the deadline until the last one disconnects. Deadlines survive a match-process restart. If a session dies while the match process itself is down, its deadline begins when the restarted match observes the dead process, not at the unknowable instant of disconnect.

ETS checkpoints are node-local and volatile: they do **not** survive VM/node or store-process failure, nor a match-supervisor failure that intentionally shuts down its children. There is no distributed recovery or durable storage. Recovery notifications are best effort; a concurrent lobby/PubSub outage can prevent notification. The supervisor permits up to 1,000 transient restarts in five seconds; a persistent failure can exhaust that limit and take down dependent services.

`mix test test/arena/match_recovery_test.exs --max-cases 2` includes 50 consecutive seeded chaos games with randomized kill positions. `mix run --no-start bench/checkpoint.exs` measures 100,000 synchronous ETS-owner writes against an empty-loop baseline using an eight-snake checkpoint. The chaos test and checkpoint cost could not be run in the current environment because Erlang/Elixir and Hex access are unavailable; no pass count or timing is claimed.

### Matchmaking and lobby

`Arena.Matchmaker.quick_play(player)` queues the calling process and monitors it; player IDs must be unique within the queue. The FIFO queue forms a match as soon as eight players are waiting, or when ten seconds have elapsed since the first queued player and at least two are available. A lone player stays queued after the deadline, and a subsequent second player starts a match immediately. If the queue becomes empty, its deadline is discarded. `cancel(player)` removes only the calling process's entry; a disconnected queued process is removed automatically. Players receive `{:match_found, match_id, player}` when selected. The selected IDs are supplied atomically when the match is created, then the usual three-second match countdown runs. Queued monitors are released after selection; handling disconnects after assignment is the transport's responsibility. If creating a match fails, queued players receive `{:matchmaking_error, player, reason}` and remain queued; the system-clock matchmaker retries after one second.

For deterministic tests, start a separate matchmaker with `name: nil, clock: :manual` and call `advance(pid, milliseconds)`; production uses monotonic time and process timers. Queue state is in-memory and is lost if the matchmaker restarts.

`create_private(player)` creates a room with its creator already joined and returns an eight-character random hexadecimal code. `join_private(code, player)` accepts the code case-insensitively and uses the normal match capacity and countdown rules. Codes are short invitations, **not authentication**; a future transport must authenticate and authorize players and rate-limit code guesses. Private rooms are omitted from public lobby snapshots. `Arena.Lobby.open_matches/0` returns public waiting/countdown matches with vacancies as `%{id: id, player_count: count, capacity: 8}`; on creation, membership/phase changes and termination the lobby broadcasts `{:lobby_updated, rooms}` on `Arena.Lobby.topic()` (`"lobby"`). Subscribers should fetch an initial snapshot separately; updates are in-memory and eventually consistent with match processes.

Supervision tree:

```mermaid
graph TD
  App["Arena.Supervisor (rest_for_one)"]
  App --> PubSub["Phoenix.PubSub (permanent)"]
  App --> Registry["Arena.MatchRegistry (permanent)"]
  App --> Store["Arena.MatchStore (permanent, ETS owner)"]
  App --> Matches["Arena.MatchSupervisor (permanent, one_for_one)"]
  Matches --> Match["Arena.Match (transient, one per match)"]
  App --> Lobby["Arena.Lobby (permanent)"]
  App --> Matchmaker["Arena.Matchmaker (permanent)"]
  App --> Tasks["Arena.TaskSupervisor (permanent)"]
  Tasks --> Task["Side-work tasks (temporary)"]
  App --> Writer["Arena.ResultWriter (permanent)"]
  App --> Repo["Arena.Repo (permanent)"]
  App --> Endpoint["ArenaWeb.Endpoint (permanent)"]
```

The application uses `:rest_for_one` in the order shown: if PubSub or the registry fails, dependent matches and services restart rather than retain invalid connections or registrations; a match supervisor failure likewise rebuilds its dependents. A lobby failure leaves matches running, and the restarted lobby discovers and monitors surviving registered children before accepting new requests. Matchmaker, task supervisor, result writer, Repo and endpoint are permanent services restarted with their dependencies; Repo is late in the order so a database failure does not terminate matches or the result writer. Individual side-work tasks are temporary. Matches are transient so abnormal exits restore the separate ETS checkpoint, while normal stops do not restart. `MatchStore` precedes the dynamic supervisor so it outlives an individual match.

## Results and leaderboard

PostgreSQL stores `players` (guest ID, display name and insertion time), `match_results` (public match ID, unique random result ID, simulation duration in milliseconds, winner IDs, reason and final scores), and `player_stats` (wins, best score and matches played). A distinct result ID is generated when a match is created, so reusing a private-room code or public match ID does not collapse two matches. Tied winners each receive a win; a result with no winners increments no win counters. All participants, including eliminated or forfeiting players, count as having played. A player is inserted on their first recorded result, using the signed display name seen on channel attachment, or a `Guest-` fallback when they never attached; a later verified name replaces a fallback.

At match end the match process atomically puts its final checkpoint and result into the ETS owner's in-memory outbox, then wakes `Arena.ResultWriter` without performing database operations. The writer starts at most two supervised tasks and retries errors with exponential backoff (one to thirty seconds). Result insertion and stat updates are one database transaction, with a unique result ID preventing duplicate wins or matches on retries or process recovery. Successful and duplicate commits publish `{:leaderboard_updated, match_id}` on `"leaderboard"`; `/leaderboard` subscribes and displays the top 20 by wins and by best score, with deterministic tie ordering. A database outage cannot block the tick loop, though the local ETS outbox can grow while writes fail. The outbox survives individual match or writer crashes but, like match checkpoints, is not durable across VM or `MatchStore` failure; queued results can be lost in that case. It is not a replacement for a durable production job queue.

`mix test test/arena/results_test.exs --max-cases 2` exercises idempotence, ties, rankings, live updates, and slow/failing PostgreSQL transactions using the Ecto SQL sandbox. It requires the configured local PostgreSQL service. The current sandbox environment has neither the pinned Elixir/OTP toolchain nor accessible Hex/PostgreSQL, so these database tests and the tick-latency assertions are not verified here.

Crash notifications are in-memory, best effort, and require a running lobby and PubSub; a lobby or PubSub outage concurrent with a match crash can lose a notification. Lobby recovery restores monitoring of surviving matches, not notifications for matches that disappeared while it was down.

## Guest identity and channel protocol

`GET /guest` issues a random guest ID and display name signed with `Phoenix.Token`, with a 30-day maximum age and `Cache-Control: no-store`. Supplying an existing token in `Authorization: Bearer <token>` returns the same identity if valid, otherwise a new identity. The `/play` example stores the token in browser local storage and connects to `/socket/websocket` using it as the `token` parameter. The socket verifies the token on connect and the channel verifies it again on join. A token is a bearer credential: use HTTPS/WSS in production, protect against XSS, and redact socket query strings from access logs. There is no revocation, account recovery, or authenticated account linkage.

Phoenix socket topic `match:<match_id>` represents a match. A valid guest may join a public match with room, or join a private match by knowing its full `room-<code>` ID. Previously assigned players may reconnect within their grace period, while new players cannot join after it starts; finished matches reject joins. Guest identity and the room code are not a substitute for full authorization or rate limiting.

| Direction | Event | Payload / meaning |
| --- | --- | --- |
| Client → server | join topic | Reply includes `player` (ID and name), `phase`, and `state` (null before start), or a reason such as `full`, `finished`, `started`, `not_found`, or `invalid_token`. |
| Client → server | `input` | `{ "direction": "up" \| "down" \| "left" \| "right" }`; a reply acknowledges or rejects it. The match buffers the latest accepted direction; the core validates turns. |
| Client → server | `ping` | Empty payload; the reply is used to measure round-trip latency. |
| Client → server | `resync` | Empty payload; reply contains the current full `state`, or an error if the match is unavailable. |
| Server → client | `status` | `{ "phase": string, "players": [player_id], "countdown_ms": integer \| null }` after joining and on membership or phase changes. |
| Server → client | `state` | `{ "state": { "tick": integer, "width": integer, "height": integer, "snakes": {...}, "food": [x,y] \| null, "result": object \| null }, "events": [...] }` on the first tick, every 30 ticks (two simulation seconds), and after joining a running match. Snakes contain head-first body cells, direction, alive flag and score. |
| Server → client | `delta` | `{ "tick": integer, "moves": {player_id: {"head": [x,y], "tail_moved": boolean, "direction": string}}, "deaths": [player_id], "scores": {player_id: new_score}, "events": [...] }`. When food changes, `food_removed` and `food_added` are included (each a cell or null); `result` is included when it changes. Stationary forfeited snakes appear in `deaths` without a move. |
| Server → client | `match_ended` | `{ "reason": "unexpected" \| "unavailable" }` when a match cannot recover or cannot be reached. Normal results appear in `state.result` and the `match_over` event. |
| Server → client | `match_recovering`, `match_recovered` | Empty payloads marking a process restart. Recovery is followed by a full snapshot/resync. |
| Server → client | `player_disconnected`, `player_reconnected` | `{ "player": player_id }` when the last session disconnects or a player reclaims their snake. |

The match serializes commands and determines their effective tick. Clients apply only the next consecutive delta, discard stale updates, and request `resync` after a gap or missing baseline; the periodic full snapshot is another recovery point. A match compares against the last *published* game, so a forfeit between ticks is included. `Arena.GameUpdates` uses Phoenix's channel fastlane dispatcher: the broadcast is encoded once per serializer per local PubSub dispatch and reused for all matching socket transports, rather than encoded once per player. Mixed serializers or distributed nodes each require their own encoding. Input sequence numbers and rate limits are not implemented.

### Message size measurement

Measured with `node --test --test-concurrency=2 test/js/bandwidth.test.mjs`: a synthetic quiet tick with eight 22-character IDs, ten cells per snake, no food change and a `match:benchmark` topic encoded as Phoenix v2 JSON frames is **1,357 bytes full** versus **731 bytes delta** (UTF-8 JSON only, excluding WebSocket framing, compression and TLS). For 30 identical-sized ticks, the previous full-every-tick scheme is **40,710 bytes**, versus **22,556 bytes** for 29 deltas and one full snapshot, a **44.6%** reduction. This is a reproducible fixture calculation, not a measured running-server workload: body lengths, deaths, events, topic length and snapshot timing change real savings, and short snakes may yield larger deltas. The Elixir serializer and live network behavior remain unverified in the current environment.

## Browser client

`/lobby` is a LiveView with quick play, room creation and code joining, and a PubSub-driven list of public open matches. A signed guest token is obtained before LiveView connects and is verified in its connected mount. The LiveView process owns its queue entry, so disconnecting while queued removes it. Selecting a match navigates to `/matches/<id>`; private match pages show the room code for sharing.

The `Game` LiveView hook opens the authenticated match channel, sends arrow/WASD directions, displays the countdown, scores, result, and a two-second ping round-trip measurement. Its `requestAnimationFrame` loop interpolates snake segments from the previous authoritative snapshot to the latest over one 15 Hz tick interval (typically drawing at 60 Hz); missing ticks trigger resynchronization and snap to the recovered state rather than extrapolating. Rendering does not change server state. Hook teardown closes the channel, socket, timer and animation loop. JavaScript is kept under `assets/js/game/`; Phoenix/LiveView ES modules are served from installed dependencies, while the game modules are embedded at compile time for releases.
