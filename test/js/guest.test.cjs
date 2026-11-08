const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

const source = fs.readFileSync(path.join(__dirname, "../../priv/static/guest.js"), "utf8");

function element() {
  return {
    handlers: {},
    textContent: "",
    value: "",
    disabled: false,
    addEventListener(type, handler) { this.handlers[type] = handler; },
  };
}

async function client(existingToken) {
  const identity = element();
  const form = element();
  const button = element();
  const match = element();
  const output = element();
  form.querySelector = () => button;
  const elements = { "#identity": identity, "#join": form, "#match": match, "#state": output };
  const document = { handlers: {}, querySelector: (id) => elements[id], addEventListener(type, fn) { this.handlers[type] = fn; } };
  const storage = new Map(existingToken ? [["arena.guestToken", existingToken]] : []);
  let request;
  let instance;

  class FakeSocket {
    static OPEN = 1;
    constructor(url) { this.url = url; this.handlers = {}; this.frames = []; this.readyState = 0; instance = this; }
    addEventListener(type, fn) { this.handlers[type] = fn; }
    send(frame) { this.frames.push(JSON.parse(frame)); }
    close() { this.readyState = 3; this.handlers.close(); }
    emit(type, value) { this.handlers[type](value); }
  }

  const context = {
    document,
    location: { protocol: "http:", host: "127.0.0.1:22300" },
    localStorage: { getItem: (key) => storage.get(key) || null, setItem: (key, value) => storage.set(key, value) },
    fetch: async (url, options) => {
      request = { url, options };
      return { ok: true, json: async () => ({ id: "guest1", name: "Guest-1", token: "signed-token" }) };
    },
    WebSocket: FakeSocket,
    URL,
    setInterval: () => 1,
    clearInterval: () => {},
  };
  vm.runInNewContext(source, context);
  await new Promise(setImmediate);
  return { identity, form, button, match, output, document, storage, request, socket: () => instance };
}

test("bootstraps and persists a guest, then joins with its signed token", async () => {
  const app = await client();
  assert.equal(app.request.url, "/guest");
  assert.equal(app.storage.get("arena.guestToken"), "signed-token");
  assert.equal(app.button.disabled, false);
  assert.match(app.identity.textContent, /Guest-1/);
  app.match.value = "example";
  app.form.handlers.submit({ preventDefault() {} });
  const socket = app.socket();
  assert.equal(socket.url.searchParams.get("token"), "signed-token");
  assert.equal(socket.url.searchParams.get("vsn"), "2.0.0");
  socket.readyState = 1;
  socket.emit("open");
  assert.deepEqual(socket.frames[0], ["1", "1", "match:example", "phx_join", {}]);
  socket.emit("message", { data: JSON.stringify(["1", "1", "match:example", "phx_reply", { status: "ok" }]) });
  let prevented = false;
  app.document.handlers.keydown({ key: "ArrowUp", preventDefault() { prevented = true; } });
  assert.equal(prevented, true);
  assert.deepEqual(socket.frames[1], ["1", "2", "match:example", "input", { direction: "up" }]);
  socket.emit("message", { data: JSON.stringify(["1", null, "match:example", "state", { state: { tick: 1 } }]) });
  assert.match(app.output.textContent, /"tick": 1/);
});

test("presents a stored token when bootstrapping", async () => {
  const app = await client("old-token");
  assert.equal(app.request.options.headers.Authorization, "Bearer old-token");
  assert.equal(app.storage.get("arena.guestToken"), "signed-token");
});
