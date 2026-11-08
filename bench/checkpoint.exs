# Run with: mix run --no-start bench/checkpoint.exs
{:ok, _pid} = Arena.MatchStore.start_link([])
game = Arena.Game.new(Enum.to_list(1..8), {1, 2, 3})
checkpoint = %{game: game, published_game: game, inputs: %{}, players: Enum.to_list(1..8)}
iterations = 100_000

{baseline_us, _} = :timer.tc(fn -> Enum.each(1..iterations, fn _ -> :ok end) end)
{checkpoint_us, _} = :timer.tc(fn ->
  Enum.each(1..iterations, fn _ -> :ok = Arena.MatchStore.put("benchmark", checkpoint) end)
end)

IO.puts("iterations=#{iterations} baseline_us=#{baseline_us} checkpoint_us=#{checkpoint_us}")
IO.puts("checkpoint_mean_us=#{checkpoint_us / iterations} incremental_mean_us=#{(checkpoint_us - baseline_us) / iterations}")
:ok = Arena.MatchStore.delete("benchmark")
