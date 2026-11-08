# Arena design

The pure game core is implemented; match processes and channel events are planned.

## Rules

Each match runs on a 40 × 30 grid with up to eight snakes. The server advances the simulation at 15 ticks per second. Snakes move one cell per tick, grow and score by eating food, and die on hitting a wall or any snake. The last snake alive wins; if the match reaches three minutes (2,700 ticks), the highest score wins. Simultaneous elimination and equal scores produce a tie. A match starts with at least two players. Food placement uses the match's explicit random seed; occupied cells are never chosen.

## Architecture

`Arena.Game` is a pure, deterministic state-transition core. Its inputs include the current state, player commands, and explicit random seed state; it performs no process operations, clock reads, or implicit random calls. A single `Arena.Match` GenServer per match will own the game state, gather commands and schedule ticks. Phoenix Channels validate and translate transport messages, forward commands to the match, and relay server snapshots; they contain no game rules. The server is authoritative: clients never submit positions, scores, or outcomes as truth.

### Core contract

`Arena.Game.new(player_ids, {a, b, c})` requires two to eight unique IDs and creates three-cell, right-facing snakes in the input order, plus one seeded food cell. Coordinates are zero-based, with x increasing right and y increasing down. Bodies are Erlang queues ordered head first. `tick(state, inputs)` accepts a map of player IDs to direction atoms and returns `{state, events}`; absent, invalid, or opposite directions retain the current direction. Unrecognized player IDs are ignored.

All live snakes propose their moves simultaneously. A non-growing snake's tail vacates before collisions; a growing snake's tail remains. A head hitting a wall, any remaining body (including its own), another proposed head, or swapping head positions with another snake dies. Snakes killed on food do not eat or grow. Dead bodies do not block future ticks or food placement. Surviving eaters score one point and grow by one cell; one new food is selected uniformly from free cells using the explicit RNG state. If no cell is free, food remains absent. Events are `{:ate, player_id, cell}`, `{:died, player_id}`, `{:food_spawned, cell}`, and `{:match_over, %{winners: ids, reason: reason}}`, in player ID order followed by food and match events. Initial food is in the returned state, not an event.

If all snakes die on the same tick, the result has no winners and reason `:simultaneous_death`; otherwise a sole survivor wins immediately. On tick 2,700, if multiple snakes remain, the highest score among all participants wins, with all tied players included. Elimination takes precedence over the time limit. A finished game does not advance or emit further events.

Planned supervision tree (only Repo, PubSub and Endpoint exist initially):

```text
Arena.Supervisor (one_for_one)
├── Arena.Repo
├── Phoenix.PubSub (Arena.PubSub)
├── Registry (match IDs)
├── DynamicSupervisor (one Arena.Match per active match)
│   └── Arena.Match
└── ArenaWeb.Endpoint (channels)
```

## Planned protocol

Phoenix socket topic `match:<match_id>` represents a match. Payloads are JSON objects. Authentication and matchmaking are outside this initial scaffold; production access must authenticate and authorize before joining.

| Direction | Event | Payload / meaning |
| --- | --- | --- |
| Client → server | join topic | Join reply contains player ID, current tick, and full snapshot, or an error such as `full` or `finished`. |
| Client → server | `input` | `{ "direction": "up" \| "down" \| "left" \| "right", "seq": integer }`; the server validates membership, sequence and legal turns. |
| Server → clients | `state` | `{ "tick": integer, "snakes": [...], "food": [...], "scores": {...} }`, an authoritative snapshot. |
| Server → clients | `finished` | `{ "tick": integer, "winners": [player_id], "reason": "last_alive" \| "time_limit" \| "simultaneous_death" }`. |
| Server → client | reply/error | Input acknowledgement or rejection; a client reconnects by rejoining and receiving a full snapshot. |

The match serializes commands and determines their effective tick; clients use tick numbers to discard stale snapshots. Input rate limits remain to be specified when the transport is implemented.
