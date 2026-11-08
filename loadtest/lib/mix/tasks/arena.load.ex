defmodule Mix.Tasks.Arena.Load do
  @moduledoc "Runs a loopback-only production-server load test."
  use Mix.Task

  @shortdoc "Run WebSocket load bots"

  @impl Mix.Task
  def run(args) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [
          bots: :integer,
          port: :integer,
          warmup: :integer,
          duration: :integer,
          ramp_ms: :integer
        ]
      )

    opts = Keyword.merge([bots: 100, port: 22300, warmup: 20, duration: 60, ramp_ms: 2], opts)

    if rest != [] or invalid != [] or opts[:bots] not in 2..10_000 or
         opts[:port] not in 22300..22399 or opts[:warmup] not in 0..300 or
         opts[:duration] not in 1..3_600 or opts[:ramp_ms] not in 0..1_000 do
      Mix.raise(
        "invalid options: --bots 2..10000 --port 22300..22399 --warmup 0..300 --duration 1..3600 --ramp-ms 0..1000"
      )
    end

    Mix.Task.run("app.start")
    ArenaLoad.Runner.run(opts)
  end
end
