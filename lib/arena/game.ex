defmodule Arena.Game do
  @moduledoc """
  Pure, server-authoritative snake simulation. See DESIGN.md for collision rules.
  """

  defmodule Snake do
    @moduledoc "A snake's body is a `:queue` ordered head first."
    @enforce_keys [:body, :direction]
    defstruct [:body, :direction, alive: true, score: 0]
  end

  @enforce_keys [:snakes, :rng]
  defstruct width: 40,
            height: 30,
            snakes: %{},
            food: nil,
            power_up: nil,
            rng: nil,
            tick: 0,
            result: nil

  @type direction :: :up | :down | :left | :right
  @type cell :: {non_neg_integer(), non_neg_integer()}
  @type t :: %__MODULE__{}

  @starts [{5, 4}, {15, 4}, {25, 4}, {35, 4}, {5, 24}, {15, 24}, {25, 24}, {35, 24}]
  @directions [:up, :down, :left, :right]
  @limit 15 * 60 * 3

  @doc "Creates a match for two to eight unique player IDs and an explicit RNG seed."
  @spec new([term()], {integer(), integer(), integer()}) :: t()
  def new(players, seed) when is_list(players) do
    if length(players) not in 2..8 or length(Enum.uniq(players)) != length(players) do
      raise ArgumentError, "a match requires two to eight unique players"
    end

    snakes =
      players
      |> Enum.zip(@starts)
      |> Map.new(fn {id, {x, y}} ->
        {id, %Snake{body: :queue.from_list([{x, y}, {x - 1, y}, {x - 2, y}]), direction: :right}}
      end)

    state = %__MODULE__{snakes: snakes, rng: :rand.seed_s(:exsss, seed)}
    {state, _} = spawn_item(state, :food)
    {state, _} = enable_power_up(state)
    state
  end

  @doc "Places a power-up on a free cell using the explicit RNG state."
  def enable_power_up(%__MODULE__{power_up: nil, result: nil} = state), do: spawn_item(state, :power_up)
  def enable_power_up(state), do: {state, []}

  @doc "Advances one tick and returns the new state and ordered events."
  @spec tick(t(), %{optional(term()) => direction()}) :: {t(), [tuple()]}
  def tick(%__MODULE__{result: result} = state, _inputs) when not is_nil(result),
    do: {state, []}

  def tick(%__MODULE__{} = state, inputs) do
    moves =
      state.snakes
      |> Enum.filter(fn {_id, snake} -> snake.alive end)
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map(fn {id, snake} -> move(id, snake, Map.get(inputs, id), state.food, state.power_up) end)

    bodies = Enum.flat_map(moves, fn move -> tl(:queue.to_list(move.body)) end) |> MapSet.new()
    heads = Enum.frequencies_by(moves, & &1.head)

    {snakes, events, eaten, power_used} =
      Enum.reduce(moves, {state.snakes, [], false, false}, fn move, {snakes, events, eaten, power_used} ->
        dead =
          outside?(state, move.head) or MapSet.member?(bodies, move.head) or
            heads[move.head] > 1 or swapped?(move, moves)

        snake = Map.fetch!(snakes, move.id)

        if dead do
          body = if move.eats, do: elem(:queue.out_r(move.body), 1), else: move.body
          snake = %{snake | body: body, direction: move.direction, alive: false}
          {Map.put(snakes, move.id, snake), [{:died, move.id} | events], eaten, power_used}
        else
          snake = %{
            snake
            | body: move.body,
              direction: move.direction,
              score: snake.score + if(move.eats, do: 1, else: 0) + if(move.power, do: 5, else: 0)
          }

          events = if move.eats, do: [{:ate, move.id, move.head} | events], else: events
          events = if move.power, do: [{:power_up_collected, move.id, move.head} | events], else: events
          {Map.put(snakes, move.id, snake), events, eaten or move.eats, power_used or move.power}
        end
      end)

    state = %{state | snakes: snakes, tick: state.tick + 1,
      food: if(eaten, do: nil, else: state.food),
      power_up: if(power_used, do: nil, else: state.power_up)}
    {state, food_events} = if eaten, do: spawn_item(state, :food), else: {state, []}
    {state, power_events} = enable_power_up(state)
    {state, over_events} = finish(state)
    {state, Enum.reverse(events) ++ food_events ++ power_events ++ over_events}
  end

  defp move(id, snake, input, food, power_up) do
    direction = if input in @directions and not opposite?(input, snake.direction), do: input, else: snake.direction
    {{:value, old_head}, _} = :queue.out(snake.body)
    head = step(old_head, direction)
    eats = head == food
    body = :queue.in_r(head, snake.body)
    body = if eats, do: body, else: elem(:queue.out_r(body), 1)
    %{id: id, head: head, old_head: old_head, body: body, direction: direction, eats: eats, power: head == power_up}
  end

  defp step({x, y}, :up), do: {x, y - 1}
  defp step({x, y}, :down), do: {x, y + 1}
  defp step({x, y}, :left), do: {x - 1, y}
  defp step({x, y}, :right), do: {x + 1, y}

  defp opposite?(:up, :down), do: true
  defp opposite?(:down, :up), do: true
  defp opposite?(:left, :right), do: true
  defp opposite?(:right, :left), do: true
  defp opposite?(_, _), do: false

  defp outside?(state, {x, y}),
    do: x < 0 or y < 0 or x >= state.width or y >= state.height

  defp swapped?(move, moves) do
    Enum.any?(moves, fn other ->
      other.id != move.id and other.head == move.old_head and other.old_head == move.head
    end)
  end

  defp spawn_item(state, item) do
    occupied =
      state.snakes
      |> Enum.filter(fn {_id, snake} -> snake.alive end)
      |> Enum.flat_map(fn {_id, snake} -> :queue.to_list(snake.body) end)
      |> MapSet.new()

    other = if item == :food, do: state.power_up, else: state.food
    free = for y <- 0..(state.height - 1), x <- 0..(state.width - 1),
      not MapSet.member?(occupied, {x, y}) and {x, y} != other, do: {x, y}

    case free do
      [] -> {state, []}
      _ ->
        {index, rng} = :rand.uniform_s(length(free), state.rng)
        position = Enum.at(free, index - 1)
        event = if item == :food, do: :food_spawned, else: :power_up_spawned
        {state |> Map.put(item, position) |> Map.put(:rng, rng), [{event, position}]}
    end
  end

  defp finish(state) do
    alive = for {id, snake} <- state.snakes, snake.alive, do: id

    result =
      cond do
        alive == [] -> %{winners: [], reason: :simultaneous_death}
        length(alive) == 1 -> %{winners: alive, reason: :last_alive}
        state.tick >= @limit ->
          best = state.snakes |> Map.values() |> Enum.map(& &1.score) |> Enum.max()
          winners = for {id, snake} <- state.snakes, snake.score == best, do: id
          %{winners: Enum.sort(winners), reason: :time_limit}

        true -> nil
      end

    if result, do: {%{state | result: result}, [{:match_over, result}]}, else: {state, []}
  end
end
