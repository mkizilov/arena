import { Socket } from "/assets/vendor/phoenix.mjs";
import { LiveSocket } from "/assets/vendor/phoenix_live_view.esm.js";
import { createGameHook } from "./hook.mjs";

async function start() {
  try {
    const token = localStorage.getItem("arena.guestToken");
    const headers = token ? { Authorization: `Bearer ${token}` } : {};
    const response = await fetch("/guest", { headers, cache: "no-store" });
    if (!response.ok) throw new Error("Could not obtain a guest identity");
    const guest = await response.json();
    localStorage.setItem("arena.guestToken", guest.token);
    const csrf = document.querySelector('meta[name="csrf-token"]').content;
    const liveSocket = new LiveSocket("/live", Socket, {
      params: () => ({ _csrf_token: csrf, guest_token: localStorage.getItem("arena.guestToken") }),
      hooks: { Game: createGameHook(Socket) },
    });
    liveSocket.connect();
  } catch (error) {
    const message = document.createElement("p");
    message.setAttribute("role", "alert");
    message.textContent = `Unable to connect: ${error.message}`;
    document.body.prepend(message);
  }
}

start();
