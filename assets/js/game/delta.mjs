export function applyDelta(state, delta) {
  if (!state || delta.tick !== state.tick + 1) return null;
  const snakes = { ...state.snakes };

  for (const [id, move] of Object.entries(delta.moves)) {
    const old = snakes[id];
    if (!old || !Array.isArray(move.head) || typeof move.tail_moved !== "boolean") return null;
    const body = [move.head, ...old.body];
    if (move.tail_moved) body.pop();
    snakes[id] = { ...old, body, direction: move.direction };
  }
  for (const id of delta.deaths) {
    if (!snakes[id]) return null;
    snakes[id] = { ...snakes[id], alive: false };
  }
  for (const [id, score] of Object.entries(delta.scores)) {
    if (!snakes[id]) return null;
    snakes[id] = { ...snakes[id], score };
  }

  return {
    ...state,
    tick: delta.tick,
    snakes,
    food: Object.hasOwn(delta, "food_added") ? delta.food_added : state.food,
    result: Object.hasOwn(delta, "result") ? delta.result : state.result,
  };
}
