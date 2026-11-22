# Stress simulator CLI.
#
#   mix run scripts/stress.exs                     # default: 200 honest + 170 cheats, 30s
#   mix run scripts/stress.exs --honest 500 --seconds 60 --seed 7
#   mix run scripts/stress.exs --loss 0.05 --jitter 60 --latency 120
#
# Scenarios exercise a realistic UDP link (latency, jitter, packet loss) so the
# honest players' reports are as ragged as real ones.

{opts, _argv, _invalid} =
  OptionParser.parse(System.argv(),
    strict: [
      honest: :integer,
      seconds: :integer,
      seed: :integer,
      dt: :integer,
      latency: :integer,
      jitter: :integer,
      loss: :float,
      cheats: :string
    ]
  )

cheat_counts =
  case Keyword.get(opts, :cheats) do
    nil ->
      nil

    spec ->
      # "speed:20,teleport:10" -> %{speed: 20, teleport: 10}
      spec
      |> String.split(",", trim: true)
      |> Map.new(fn pair ->
        [k, v] = String.split(pair, ":", parts: 2)
        {String.to_existing_atom(k), String.to_integer(v)}
      end)
  end

runner_opts =
  [
    honest: Keyword.get(opts, :honest, 200),
    seconds: Keyword.get(opts, :seconds, 30),
    seed: Keyword.get(opts, :seed, 1),
    dt_ms: Keyword.get(opts, :dt, 100),
    net: [
      latency_ms: Keyword.get(opts, :latency, 50),
      jitter_ms: Keyword.get(opts, :jitter, 20),
      loss: Keyword.get(opts, :loss, 0.01)
    ]
  ]
  |> then(fn o -> if cheat_counts, do: Keyword.put(o, :cheats, cheat_counts), else: o end)

result = Aegis.Sim.Runner.run(runner_opts)

IO.puts(Aegis.Sim.Report.render(result))
