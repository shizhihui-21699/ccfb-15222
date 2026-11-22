# Microbenchmark: validator cost per packet, isolated from the simulator.
alias Aegis.{Player, Rules, Validator}

map = Aegis.Map.Canyon.build()
Aegis.Map.install(map)
rules = Rules.new()

# Build a state that is mid-walk in open ground.
p =
  Player.new(:bench, {100.0, 70.0}, 0)

# Pre-build a batch of legal 20Hz move packets (0.33m each) with realistic
# client timestamps, then replay them many times against fresh state.
n = 200_000

packets =
  for i <- 1..n do
    %{seq: i, pos: {100.0 + 0.33 * rem(i, 100), 70.0 + 0.01 * rem(i, 50)}, client_ts: i * 50}
  end

run = fn ->
  {_p, _} =
    Enum.reduce(packets, {p, 0}, fn pkt, {pl, t} ->
      t2 = t + 50
      {_v, pl2} = Validator.handle_move(map, rules, pl, pkt, t2)
      {pl2, t2}
    end)
end

# warmup
run.()

{us, _} = :timer.tc(run)
IO.puts("move validation: #{n} packets in #{Float.round(us / 1_000_000, 3)}s")
IO.puts("  #{(us / n) |> Float.round(3)} µs/packet")
IO.puts("  #{round(n / (us / 1_000_000))} packets/s single core")

# Attack validation cost
victim = Player.new(:v, {108.0, 70.0}, 0)
lookup = fn _ -> victim end

attacks =
  for i <- 1..n,
      do: %{
        target: :v,
        victim_pos: {108.0, 70.0},
        client_ts: i * 200,
        attacker_pos: {100.0, 70.0}
      }

run2 = fn ->
  {_p, _} =
    Enum.reduce(attacks, {p, 0}, fn pkt, {pl, t} ->
      t2 = t + 200
      {_v, pl2} = Validator.handle_attack(map, rules, pl, pkt, t2, lookup)
      {pl2, t2}
    end)
end

run2.()
{us2, _} = :timer.tc(run2)
IO.puts("attack validation: #{n} packets in #{Float.round(us2 / 1_000_000, 3)}s")
IO.puts("  #{(us2 / n) |> Float.round(3)} µs/packet")
IO.puts("  #{round(n / (us2 / 1_000_000))} packets/s single core")
