# Arena: project boundaries and working agreement

- Work only in `/Users/mk-rune/test_projects/14-arena`. This is one of fourteen independent repositories.
- Do not read, modify, clean up, or run commands in sibling repositories or the user's configuration.
- Work autonomously: choose sensible defaults and document assumptions; do not ask questions or delegate.
- Never install anything globally or use sudo, Homebrew, launchd, host credentials, or host Docker sockets.
- Dependencies, toolchains, caches, browser binaries, SDKs, temporary files and test data stay in this repository. Preserve the supplied project-local environment. Python packages go in `.venv`.
- `.agent-local/` is ignored, project-local build/runtime state. Preserve the supplied sandbox and isolation boundaries.
- Use existing system tools read-only, or install pinned tools under this repository. Do not change shell profiles, user settings, Keychain, or global Git settings.
- Bind test servers to loopback; use ports 22300–22399. Limit build/test workers to two unless a required benchmark explicitly needs more.
- Docker-dependent integration tests must remain reproducible but be reported as unverified here if they require access outside this repository. Do not bypass this boundary.
- Do not touch attached hardware, enroll services, flash firmware, install agents, or alter OS settings. Supply manual checklists for such steps.
- Implement only the requested task, preserving prior behavior. Run appropriate checks, fix failures, and report genuine limitations without fabricating test or benchmark results.
- Before finishing a task: stop its servers/watchers, remove scratch outputs, update relevant documentation, and make a local conventional-commit Git commit. Do not push.
- End each task with a short summary of changes, checks actually run, remaining limitations, and commit hash.

## Elixir architecture and verification

- Keep `Arena.Game` pure and deterministic: no processes, time calls, or randomness without explicit seed state. A match process owns scheduling and state; channel modules are transport only and contain no game logic.
- Match processes use Horde and replicated ETS checkpoints; persistence and its retry outbox are separate from the tick loop. See `DESIGN.md` for architecture and limitations.
- Run `mix compile --warnings-as-errors`, `mix test`, `mix format --check-formatted`, `mix credo --strict`, and `mix dialyzer`, or run all five with `mix check`.
- Run client tests with `node --test --test-concurrency=2 test/js/*.test.*`.
- Definition of done for every future task: `mix check` passes, new code has tests, documentation is updated, provide a short summary, and make a conventional-commit Git commit.
- Distributed cluster tests require a loopback-only distributed VM and project-scoped EPMD on port 22351, with distribution ports 22352–22359; see `DESIGN.md`. `LocalCluster.start/0` starts an unrestricted boot server on other ports, so do not call it under these boundaries.
