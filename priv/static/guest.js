(() => {
  const identity = document.querySelector("#identity");
  const form = document.querySelector("#join");
  const matchInput = document.querySelector("#match");
  const output = document.querySelector("#state");
  const button = form.querySelector("button");
  const storageKey = "arena.guestToken";
  const directions = { ArrowUp: "up", ArrowDown: "down", ArrowLeft: "left", ArrowRight: "right" };
  let guest;
  let connection;
  let sequence = 0;

  button.disabled = true;

  async function bootstrap() {
    try {
      const token = localStorage.getItem(storageKey);
      const headers = token ? { Authorization: `Bearer ${token}` } : {};
      const response = await fetch("/guest", { headers, cache: "no-store" });
      if (!response.ok) throw new Error("Guest identity unavailable");
      guest = await response.json();
      localStorage.setItem(storageKey, guest.token);
      identity.textContent = `${guest.name} (${guest.id})`;
      button.disabled = false;
    } catch (error) {
      identity.textContent = `Unable to start: ${error.message}`;
    }
  }

  function nextRef() {
    sequence += 1;
    return String(sequence);
  }

  form.addEventListener("submit", (event) => {
    event.preventDefault();
    const id = matchInput.value.trim();
    if (!guest || !id) return;
    if (connection) connection.socket.close();

    const protocol = location.protocol === "https:" ? "wss:" : "ws:";
    const url = new URL(`${protocol}//${location.host}/socket/websocket`);
    url.searchParams.set("vsn", "2.0.0");
    url.searchParams.set("token", guest.token);
    const socket = new WebSocket(url);
    const joinRef = nextRef();
    const current = { socket, joinRef, topic: `match:${id}`, joined: false, heartbeat: null };
    connection = current;

    socket.addEventListener("open", () => {
      if (connection !== current) return;
      socket.send(JSON.stringify([joinRef, joinRef, current.topic, "phx_join", {}]));
      current.heartbeat = setInterval(() => {
        if (socket.readyState === WebSocket.OPEN) {
          socket.send(JSON.stringify([null, nextRef(), "phoenix", "heartbeat", {}]));
        }
      }, 25_000);
    });

    socket.addEventListener("message", (message) => {
      if (connection !== current) return;
      const [, ref, topic, eventName, payload] = JSON.parse(message.data);
      if (topic !== current.topic) return;
      if (eventName === "phx_reply" && ref === joinRef) {
        current.joined = payload.status === "ok";
      }
      output.textContent = JSON.stringify({ event: eventName, payload }, null, 2);
    });

    socket.addEventListener("close", () => {
      clearInterval(current.heartbeat);
      current.joined = false;
      if (connection === current) output.textContent = "Disconnected";
    });
  });

  document.addEventListener("keydown", (event) => {
    const direction = directions[event.key];
    if (!direction || !connection || !connection.joined || connection.socket.readyState !== WebSocket.OPEN) return;
    event.preventDefault();
    connection.socket.send(JSON.stringify([connection.joinRef, nextRef(), connection.topic, "input", { direction }]));
  });

  bootstrap();
})();
