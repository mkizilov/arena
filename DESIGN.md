# Arena design

This document describes the planned game; gameplay and channel events are not yet implemented.

## Rules

Each match runs on a 40 × 30 grid with up to eight snakes. The server advances the simulation at 15 ticks per second. Snakes move one cell per tick, grow and score by eating food, and die on hitting a wall or any snake. The last snake alive wins; if the match reaches three minutes (2,700 ticks), the highest score wins. Simultaneous elimination and equal scores produce a tie. A match starts with at least two players. Food placement uses the match's explicit random seed; occupied cells are never chosen.

## Architecture

`Arena.Game` will be a pure, deterministic state-transition core. Its inputs include the current state, player commands, and explicit random seed state; it performs no process operations, clock reads, or implicit random calls. A single `Arena.Match` GenServer per match owns the game state, gathers commands and schedules ticks. Phoenix Channels validate and translate transport messages, forward commands to the match, and relay server snapshots; they contain no game rules. The server is authoritative: clients never submit positions, scores, or outcomes as truth.

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

The match serializes commands and determines their effective tick; clients use tick numbers to discard stale snapshots. Exact collision ordering and input rate limits will be specified and tested when the simulation is implemented.
