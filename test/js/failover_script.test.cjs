const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { spawnSync } = require("node:child_process");

const root = path.resolve(__dirname, "../..");
const script = path.join(root, "scripts/compose_failover.sh");
const mockDocker = `#!/bin/sh
printf '%s\n' "$*" >> "$MOCK_LOG"
case "$*" in
  *" ps -q app1"*) echo app1-container ;;
  *" ps -q app2"*) echo app2-container ;;
  *" ps -q nginx"*) echo nginx-container ;;
  *"Arena.Match.start_match"*) echo "ARENA_MATCH aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa test_instance" ;;
  *"Arena.MatchReplica.get"*) if [ "$MOCK_BACKUP_FAIL" = 1 ]; then echo ARENA_WAIT; else echo ARENA_BACKUP_OK; fi ;;
  *"ARENA_RESUMED"*) echo ARENA_RESUMED ;;
  *"ARENA_CLEANED"*) if [ "$MOCK_CLEANUP_FAIL" = 1 ]; then exit 1; else echo ARENA_CLEANED; fi ;;
  *" kill -s KILL app1"*) : ;;
  *" up -d --no-deps app1"*) : ;;
  *) echo "unexpected mock command: $*" >&2; exit 1 ;;
esac
`;

function fixture(t) {
  const local = path.join(root, ".agent-local");
  const createdLocal = !fs.existsSync(local);
  fs.mkdirSync(local, { recursive: true });
  const dir = fs.mkdtempSync(path.join(local, "failover-test-"));
  t.after(() => {
    fs.rmSync(dir, { recursive: true, force: true });
    if (createdLocal) {
      try { fs.rmdirSync(local); } catch (error) { if (error.code !== "ENOTEMPTY") throw error; }
    }
  });
  const docker = path.join(dir, "docker");
  fs.writeFileSync(docker, mockDocker, { mode: 0o755 });
  fs.writeFileSync(path.join(dir, "curl"), '#!/bin/sh\nprintf "curl %s\\n" "$*" >> "$MOCK_LOG"\n[ "$MOCK_CURL_FAIL" != 1 ]\n', { mode: 0o755 });
  const log = path.join(dir, "calls.log");
  const env = { ...process.env, PATH: `${dir}:${process.env.PATH}`, MOCK_LOG: log, ARENA_COMPOSE_PROJECT: "arena-test" };
  return { env, log };
}

function run(env, args = ["--confirm"]) {
  return spawnSync("sh", [script, ...args], { cwd: root, env, encoding: "utf8", timeout: 5000 });
}

test("requires explicit confirmation before invoking Docker", (t) => {
  const { env, log } = fixture(t);
  const result = run(env, []);
  assert.equal(result.status, 2);
  assert.equal(fs.existsSync(log), false);
});

test("checks the replica, kills only app1, verifies recovery and restores it", (t) => {
  const { env, log } = fixture(t);
  const result = run(env);
  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stdout, /Recovered identical tick 3/);
  const calls = fs.readFileSync(log, "utf8");
  assert.ok(calls.indexOf("Arena.MatchReplica.get") < calls.indexOf("kill -s KILL app1"));
  assert.match(calls, /ARENA_RESUMED/);
  assert.match(calls, /curl .*127\.0\.0\.1:22300\/healthz/);
  assert.match(calls, /ARENA_CLEANED/);
  assert.match(calls, /up -d --no-deps app1/);
});

test("refuses to kill without a matching backup and still cleans its match", (t) => {
  const { env, log } = fixture(t);
  const result = run({ ...env, MOCK_BACKUP_FAIL: "1" });
  assert.equal(result.status, 1);
  const calls = fs.readFileSync(log, "utf8");
  assert.doesNotMatch(calls, /kill -s KILL/);
  assert.match(calls, /ARENA_CLEANED/);
});

test("reports cleanup failures while still restoring app1", (t) => {
  const { env, log } = fixture(t);
  const result = run({ ...env, MOCK_CLEANUP_FAIL: "1" });
  assert.equal(result.status, 1);
  assert.match(result.stderr, /Could not confirm cleanup/);
  assert.match(fs.readFileSync(log, "utf8"), /up -d --no-deps app1/);
});

test("reports a failed nginx probe and still cleans up", (t) => {
  const { env, log } = fixture(t);
  const result = run({ ...env, MOCK_CURL_FAIL: "1" });
  assert.equal(result.status, 1);
  assert.match(result.stderr, /nginx liveness probe failed/);
  const calls = fs.readFileSync(log, "utf8");
  assert.match(calls, /ARENA_CLEANED/);
  assert.match(calls, /up -d --no-deps app1/);
});
