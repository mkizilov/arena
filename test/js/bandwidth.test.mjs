import test from "node:test";
import assert from "node:assert/strict";
import { applyDelta } from "../../assets/js/game/delta.mjs";

test("measure representative eight-snake WebSocket frames", () => {
  const snakes = {};
  const moves = {};
  for (let i = 0; i < 8; i += 1) {
    const id = `p${String(i).padStart(21, "0")}`;
    snakes[id] = {
      body: Array.from({ length: 10 }, (_, segment) => [19 - segment, i * 2]),
      direction: "right", alive: true, score: 7,
    };
    moves[id] = { head: [20, i * 2], tail_moved: true, direction: "right" };
  }
  const previous = { tick: 100, width: 40, height: 30, snakes, food: [25, 25], result: null };
  const delta = { tick: 101, moves, deaths: [], scores: {}, events: [] };
  const current = applyDelta(previous, delta);
  const frame = (event, payload) => Buffer.byteLength(JSON.stringify([null, null, "match:benchmark", event, payload]));
  const fullBytes = frame("state", { state: current, events: [] });
  const deltaBytes = frame("delta", delta);
  const cycleBytes = 29 * deltaBytes + fullBytes;
  console.log(`Synthetic frames: full=${fullBytes} B delta=${deltaBytes} B; 30 ticks: before=${30 * fullBytes} B after=${cycleBytes} B`);
  assert.ok(deltaBytes < fullBytes);
});
