import { TICK_MS, directionForKey, drawBoard } from "./render.mjs";
import { applyDelta } from "./delta.mjs";

export function createGameHook(Socket) {
  return {
  mounted() {
    this.canvas = this.el.querySelector("[data-canvas]");
    this.ctx = this.canvas.getContext("2d");
    this.status = this.el.querySelector("[data-status]");
    this.latency = this.el.querySelector("[data-latency]");
    this.scores = this.el.querySelector("[data-scores]");
    this.result = this.el.querySelector("[data-result]");
    this.current = null;
    this.previous = null;
    this.receivedAt = 0;
    this.countdownEnd = null;
    this.phase = "connecting";
    this.destroyedFlag = false;

    this.keydown = (event) => {
      const direction = directionForKey(event.key);
      if (!direction || event.target?.isContentEditable || /^(INPUT|TEXTAREA|SELECT)$/.test(event.target?.tagName || "")) return;
      if (this.channel && this.phase === "running") {
        event.preventDefault();
        this.channel.push("input", { direction });
      }
    };
    window.addEventListener("keydown", this.keydown);

    const token = localStorage.getItem("arena.guestToken");
    if (!token) {
      this.status.textContent = "Guest identity unavailable. Return to the lobby.";
      return;
    }

    this.socket = new Socket("/socket", { params: { token } });
    this.socket.connect();
    this.channel = this.socket.channel(`match:${this.el.dataset.matchId}`, {});
    this.channel.on("status", (status) => this.setStatus(status));
    this.channel.on("state", ({ state }) => this.setState(state));
    this.channel.on("delta", (delta) => this.receiveDelta(delta));
    this.channel.on("match_recovering", () => {
      this.phase = "recovering";
      this.status.textContent = "Recovering match…";
    });
    this.channel.on("match_recovered", () => {
      this.status.textContent = "Match recovered. Synchronizing…";
      this.resyncing = false;
      this.requestResync();
    });
    this.channel.on("match_ended", ({ reason }) => {
      this.phase = "ended";
      this.status.textContent = `Match ended: ${reason}`;
    });
    this.channel.onError(() => {
      this.phase = "disconnected";
      this.status.textContent = "Match connection lost.";
    });
    this.channel.join()
      .receive("ok", (reply) => {
        this.setStatus(reply);
        if (reply.state) this.setState(reply.state);
        clearInterval(this.pingTimer);
        this.ping();
        this.pingTimer = setInterval(() => this.ping(), 2000);
      })
      .receive("error", ({ reason }) => { this.status.textContent = `Unable to join: ${reason}`; })
      .receive("timeout", () => { this.status.textContent = "Match connection timed out."; });

    const frame = (now) => {
      if (this.destroyedFlag) return;
      const alpha = Math.max(0, Math.min(1, (now - this.receivedAt) / TICK_MS));
      drawBoard(this.ctx, this.current, this.previous, alpha);
      if (this.phase === "countdown" && this.countdownEnd !== null) {
        this.status.textContent = `Starting in ${Math.ceil(Math.max(0, this.countdownEnd - now) / 1000)}…`;
      }
      this.frameId = requestAnimationFrame(frame);
    };
    this.frameId = requestAnimationFrame(frame);
  },

  setStatus({ phase, countdown_ms: countdownMs }) {
    this.phase = phase;
    this.countdownEnd = phase === "countdown" && Number.isFinite(countdownMs)
      ? performance.now() + countdownMs : null;
    this.status.textContent = phase === "countdown" ? "Starting…" : `Match: ${phase}`;
  },

  setState(state) {
    if (!state || (this.current && state.tick <= this.current.tick)) return;
    this.resyncing = false;
    this.previous = this.current && state.tick === this.current.tick + 1 ? this.current : null;
    this.current = state;
    this.receivedAt = performance.now();
    const rows = Object.entries(state.snakes).sort((a, b) => b[1].score - a[1].score).map(([id, snake]) => {
      const row = document.createElement("li");
      row.textContent = `${id}: ${snake.score}${snake.alive ? "" : " (out)"}`;
      return row;
    });
    this.scores.replaceChildren(...rows);
    if (state.result) {
      const winners = state.result.winners.length ? state.result.winners.join(", ") : "No winner";
      this.result.textContent = `Result: ${winners} (${state.result.reason})`;
    }
  },

  receiveDelta(delta) {
    if (this.current && delta.tick <= this.current.tick) return;
    const next = applyDelta(this.current, delta);
    if (next) {
      this.setState(next);
    } else {
      this.requestResync();
    }
  },

  requestResync() {
    if (!this.resyncing) {
      this.resyncing = true;
      this.channel.push("resync", {})
        .receive("ok", ({ state, phase, countdown_ms: countdownMs }) => {
          this.resyncing = false;
          if (phase) this.setStatus({ phase, countdown_ms: countdownMs });
          this.setState(state);
        })
        .receive("error", () => { this.resyncing = false; })
        .receive("timeout", () => { this.resyncing = false; });
    }
  },

  ping() {
    const sentAt = performance.now();
    this.channel.push("ping", {}).receive("ok", () => {
      if (!this.destroyedFlag) this.latency.textContent = `${Math.round(performance.now() - sentAt)} ms`;
    });
  },

  destroyed() {
    this.destroyedFlag = true;
    window.removeEventListener("keydown", this.keydown);
    cancelAnimationFrame(this.frameId);
    clearInterval(this.pingTimer);
    if (this.channel) this.channel.leave();
    if (this.socket) this.socket.disconnect();
  },
  };
}
