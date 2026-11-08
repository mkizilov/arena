export const TICK_MS = 1000 / 15;

const colors = ["#22c55e", "#38bdf8", "#fbbf24", "#f472b6", "#a78bfa", "#fb923c", "#2dd4bf", "#e879f9"];
const directions = new Map([
  ["ArrowUp", "up"], ["ArrowDown", "down"], ["ArrowLeft", "left"], ["ArrowRight", "right"],
  ["w", "up"], ["s", "down"], ["a", "left"], ["d", "right"],
  ["W", "up"], ["S", "down"], ["A", "left"], ["D", "right"],
]);

export function directionForKey(key) {
  return directions.get(key) || null;
}

export function interpolateBody(previous, current, amount) {
  const alpha = Math.max(0, Math.min(1, amount));
  return current.map((cell, index) => {
    const old = previous[index] || previous[previous.length - 1] || cell;
    return [old[0] + (cell[0] - old[0]) * alpha, old[1] + (cell[1] - old[1]) * alpha];
  });
}

function colorFor(id) {
  let hash = 0;
  for (const character of id) hash = ((hash * 31) + character.charCodeAt(0)) >>> 0;
  return colors[hash % colors.length];
}

export function drawBoard(ctx, current, previous, alpha) {
  const canvas = ctx.canvas;
  ctx.fillStyle = "#111827";
  ctx.fillRect(0, 0, canvas.width, canvas.height);
  if (!current) return;
  const cellWidth = canvas.width / current.width;
  const cellHeight = canvas.height / current.height;

  if (current.food) {
    ctx.fillStyle = "#ef4444";
    ctx.fillRect(current.food[0] * cellWidth, current.food[1] * cellHeight, cellWidth, cellHeight);
  }

  for (const [id, snake] of Object.entries(current.snakes)) {
    if (!snake.alive) continue;
    const prior = previous?.snakes[id]?.body || snake.body;
    ctx.fillStyle = colorFor(id);
    for (const [x, y] of interpolateBody(prior, snake.body, alpha)) {
      ctx.fillRect(x * cellWidth, y * cellHeight, cellWidth - 1, cellHeight - 1);
    }
  }
}
