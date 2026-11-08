import test from "node:test";
import assert from "node:assert/strict";
import { interpolateBody, directionForKey, drawBoard } from "../../assets/js/game/render.mjs";
import { createGameHook } from "../../assets/js/game/hook.mjs";

test("interpolates moving and growing segments and clamps the fraction", () => {
  const old = [[1, 1], [0, 1]];
  const next = [[2, 1], [1, 1], [0, 1]];
  assert.deepEqual(interpolateBody(old, next, 0.5), [[1.5, 1], [0.5, 1], [0, 1]]);
  assert.deepEqual(interpolateBody(old, next, -1), [[1, 1], [0, 1], [0, 1]]);
  assert.deepEqual(interpolateBody(old, next, 2), next);
  assert.deepEqual(old, [[1, 1], [0, 1]]);
});

test("maps arrow and WASD keys without treating other keys as input", () => {
  for (const key of ["ArrowUp", "w", "W"]) assert.equal(directionForKey(key), "up");
  assert.equal(directionForKey("ArrowDown"), "down");
  assert.equal(directionForKey("a"), "left");
  assert.equal(directionForKey("D"), "right");
  assert.equal(directionForKey("x"), null);
  assert.equal(directionForKey("toString"), null);
});

test("draws food and interpolated live snake cells on the canvas", () => {
  const rectangles = [];
  const ctx = { canvas: { width: 400, height: 300 }, fillRect(...args) { rectangles.push([this.fillStyle, ...args]); } };
  const previous = { snakes: { a: { body: [[1, 1]] } } };
  const state = { width: 40, height: 30, food: [4, 5], snakes: { a: { alive: true, body: [[2, 1]] }, b: { alive: false, body: [[3, 1]] } } };
  drawBoard(ctx, state, previous, 0.5);
  assert.equal(rectangles.length, 3);
  assert.deepEqual(rectangles[1].slice(1), [40, 50, 10, 10]);
  assert.deepEqual(rectangles[2].slice(1), [15, 10, 9, 9]);
});

test("hook joins, sends controls and ping, updates scores, countdown and result, then cleans up", (t) => {
  const names = ["window", "document", "localStorage", "requestAnimationFrame", "cancelAnimationFrame", "setInterval", "clearInterval"];
  const originals = new Map(names.map((name) => [name, Object.getOwnPropertyDescriptor(globalThis, name)]));
  t.after(() => {
    for (const [name, descriptor] of originals) {
      if (descriptor) Object.defineProperty(globalThis, name, descriptor);
      else delete globalThis[name];
    }
  });

  const status = { textContent: "" };
  const latency = { textContent: "" };
  const scores = { replaceChildren(...rows) { this.rows = rows; } };
  const result = { textContent: "" };
  const ctx = { canvas: { width: 800, height: 600 }, fillRect() {} };
  const canvas = { getContext: () => ctx };
  const elements = { "[data-canvas]": canvas, "[data-status]": status, "[data-latency]": latency, "[data-scores]": scores, "[data-result]": result };
  const events = {};
  let frame;
  let removed = false;
  globalThis.window = { addEventListener: (name, fn) => { events[name] = fn; }, removeEventListener: () => { removed = true; } };
  globalThis.document = { createElement: () => ({ textContent: "" }) };
  globalThis.localStorage = { getItem: () => "token" };
  globalThis.requestAnimationFrame = (fn) => { frame = fn; return 11; };
  globalThis.cancelAnimationFrame = () => {};
  globalThis.setInterval = () => 22;
  globalThis.clearInterval = () => {};

  const sent = [];
  const handlers = {};
  const reply = { phase: "running", state: null };
  const channel = {
    on: (name, fn) => { handlers[name] = fn; },
    onError: () => {},
    join: () => ({ receive(status, fn) { if (status === "ok") fn(reply); return this; } }),
    push: (name, payload) => {
      sent.push([name, payload]);
      return { receive(status, fn) { if (status === "ok") fn({}); return this; } };
    },
    leave() { this.left = true; },
  };
  class FakeSocket {
    constructor(path, opts) { assert.equal(path, "/socket"); assert.equal(opts.params.token, "token"); }
    connect() {}
    channel(topic) { assert.equal(topic, "match:abc"); return channel; }
    disconnect() { this.closed = true; }
  }

  const hook = Object.assign({ el: { dataset: { matchId: "abc" }, querySelector: (key) => elements[key] } }, createGameHook(FakeSocket));
  hook.mounted();
  assert.equal(sent[0][0], "ping");
  assert.match(latency.textContent, /ms$/);
  let prevented = false;
  events.keydown({ key: "w", target: { tagName: "BODY" }, preventDefault: () => { prevented = true; } });
  assert.equal(prevented, true);
  assert.deepEqual(sent[1], ["input", { direction: "up" }]);
  handlers.state({ state: { tick: 1, width: 40, height: 30, food: null, snakes: { a: { body: [[1, 1]], score: 2, alive: true } }, result: null } });
  assert.equal(scores.rows[0].textContent, "a: 2");
  handlers.state({ state: { tick: 1, snakes: {}, result: null } });
  assert.equal(scores.rows[0].textContent, "a: 2");
  handlers.status({ phase: "countdown", countdown_ms: 3000 });
  frame(performance.now());
  assert.match(status.textContent, /Starting in [123]/);
  handlers.state({ state: { tick: 2, width: 40, height: 30, food: null, snakes: { a: { body: [[2, 1]], score: 2, alive: true } }, result: { winners: ["a"], reason: "last_alive" } } });
  assert.match(result.textContent, /a \(last_alive\)/);
  hook.destroyed();
  assert.equal(removed, true);
  assert.equal(channel.left, true);
  assert.equal(hook.socket.closed, true);
});
