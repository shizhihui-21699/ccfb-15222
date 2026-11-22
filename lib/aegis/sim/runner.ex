defmodule Aegis.Sim.Runner do
  @moduledoc """
  Discrete-event stress harness.

  ## Model

  Simulated time advances in ticks (`dt_ms`, default 100ms). On each tick every
  actor produces the packets a client would send; `Aegis.Sim.Net` schedules
  each for delivery at `send + latency + jitter` and drops a fraction. The
  server drains delivered packets in receive order and calls the same
  `Aegis.Validator` functions production uses.

  It is a single deterministic timeline - not N processes calling the validator
  - so results are reproducible from a seed and the per-packet server cost is
  measurable with one `:timer.tc/1`.

  ## Accounting

    * **detection** (true positive): a cheat packet the validator rejects or
      corrects.
    * **false positive**: an honest packet rejected/corrected, or an honest
      actor that ends with any violation.
    * **false negative**: a cheat attack the validator *accepts* (a stolen hit),
      or a cheat actor that ends with no violation at all.
  """

  alias Aegis.{Player, Rules, Validator}
  alias Aegis.Sim.{Actor, Net}

  @cheat_profiles [:speed, :teleport, :noclip, :aimbot_range, :aimbot_wall, :spin, :flash]

  def default_opts do
    [
      honest: 200,
      cheats: %{
        speed: 30,
        teleport: 30,
        noclip: 30,
        aimbot_range: 20,
        aimbot_wall: 20,
        spin: 20,
        flash: 20
      },
      seconds: 30,
      dt_ms: 100,
      seed: 1,
      net: [latency_ms: 50, jitter_ms: 20, loss: 0.01],
      rules: [],
      map: nil
    ]
  end

  def run(opts \\ []) do
    opts = Keyword.merge(default_opts(), opts)
    map = opts[:map] || Aegis.Map.Canyon.build()
    Aegis.Map.install(map, :aegis_map)

    rules = Rules.new(opts[:rules])
    net = Net.new(opts[:net])
    dt = opts[:dt_ms]
    ticks = div(opts[:seconds] * 1000, dt)

    actors = build_actors(map, opts, rules, dt)

    # The server knows where each player spawns. Seed authoritative state from
    # the actor's true start (t=0) so the first delivered packet is a normal
    # zero-distance report. Without this, an attack packet arriving before the
    # actor's first move would create the player at the map spawn and the next
    # move would look like a teleport.
    players = Map.new(actors, fn a -> {a.id, Player.new(a.id, a.pos, 0)} end)
    rng = Net.seeded(opts[:seed] + 977)

    st = %{
      map: map,
      rules: rules,
      net: net,
      dt_ms: dt,
      rng: rng,
      players: players,
      pending: :gb_sets.empty(),
      stats: blank_stats(actors)
    }

    {elapsed_us, {final, actors}} =
      :timer.tc(fn ->
        Enum.reduce(0..(ticks - 1), {st, actors}, fn tick, {st, actors} ->
          tick_run(st, actors, tick * dt)
        end)
      end)

    report(final, actors, dt, ticks, elapsed_us)
  end

  # ------------------------------------------------------------------
  # Setup
  # ------------------------------------------------------------------

  defp build_actors(map, opts, rules, dt) do
    honest =
      for i <- iota(opts[:honest]) do
        Actor.new({:honest, i}, :honest, map,
          speed: rules.max_speed,
          dt_ms: dt,
          seed: 100_000 + i,
          profile_opts: %{cooldown: rules.weapon.cooldown_ms + 250}
        )
      end

    cheats =
      Enum.flat_map(opts[:cheats], fn {profile, n} ->
        for i <- iota(n) do
          Actor.new({profile, i}, profile, map,
            speed: rules.max_speed,
            dt_ms: dt,
            seed: 200_000 + profile_index(profile) * 1_000 + i,
            profile_opts: cheat_opts(profile, rules)
          )
        end
      end)

    Enum.with_index(honest ++ cheats, fn a, i -> %{a | id: i} end)
    |> Enum.map(fn a -> %{a | id: {a.profile, a.id}} end)
  end

  defp profile_index(p), do: Enum.find_index(@cheat_profiles, &(&1 == p)) || 0

  defp iota(0), do: []
  defp iota(n), do: 1..n

  defp cheat_opts(:speed, _), do: %{factor: 2.0}
  defp cheat_opts(:teleport, _), do: %{teleport_ms: 4_000}
  defp cheat_opts(:noclip, _), do: %{noclip_target: {106.0, 40.0}, noclip_home: {96.0, 40.0}}
  defp cheat_opts(:aimbot_range, r), do: %{cooldown: r.weapon.cooldown_ms + 400}
  defp cheat_opts(:aimbot_wall, r), do: %{cooldown: r.weapon.cooldown_ms + 400}
  defp cheat_opts(:spin, _), do: %{}
  defp cheat_opts(:flash, _), do: %{teleport_ms: 3_000, cooldown: 300}
  defp cheat_opts(_, _), do: %{}

  defp blank_stats(actors) do
    per =
      Map.new(actors, fn a ->
        {a.id,
         %{
           profile: a.profile,
           moves: 0,
           move_rejected: 0,
           attacks: 0,
           attacks_rejected: 0,
           violations: %{}
         }}
      end)

    %{per: per, packets: 0}
  end

  # ------------------------------------------------------------------
  # One tick: generate, schedule, deliver
  # ------------------------------------------------------------------

  defp tick_run(st, actors, now) do
    # Actors see the server's authoritative positions of *other* players, not
    # the simulator's ground truth. This is what a real client receives.
    targets =
      Enum.map(actors, fn a ->
        case Map.get(st.players, a.id) do
          nil -> {a.id, a.pos}
          p -> {a.id, p.pos}
        end
      end)

    ctx = %{map: st.map, targets: targets, weapon_range: st.rules.weapon.range, dt_ms: st.dt_ms}

    {actors, scheduled, rng} =
      Enum.reduce(actors, {[], [], st.rng}, fn a, {acc, sched, rng} ->
        {a2, packets} = Actor.step(a, now, ctx)

        # Clients only know other players' *authoritative* positions (that is
        # what the server broadcasts). Rewrite the claimed victim position to
        # the server's current authoritative one, exactly as a real client
        # would have it. Cheat profiles still get to lie about range/cooldown
        # elsewhere; an honest actor thus aims at what the server says.
        packets =
          Enum.map(packets, fn
            %{type: :attack} = pkt ->
              case Map.get(st.players, pkt.target) do
                nil -> pkt
                tp -> %{pkt | victim_pos: tp.pos}
              end

            other ->
              other
          end)

        a2 = Actor.ack(a2, packets)

        {sched, rng} =
          Enum.reduce(packets, {sched, rng}, fn pkt, {s, rng} ->
            case Net.send(st.net, now, rng) do
              {:lost, rng} -> {s, rng}
              {:ok, recv, rng} -> {[{recv, a.id, pkt} | s], rng}
            end
          end)

        {[a2 | acc], sched, rng}
      end)

    actors = Enum.reverse(actors)

    pending = Enum.reduce(scheduled, st.pending, fn e, acc -> :gb_sets.add(e, acc) end)

    st = %{st | rng: rng}
    drain(st, actors, pending, now)
  end

  defp drain(st, actors, pending, now) do
    cond do
      :gb_sets.is_empty(pending) ->
        {%{st | pending: pending}, actors}

      elem(:gb_sets.smallest(pending), 0) > now ->
        {%{st | pending: pending}, actors}

      true ->
        {entry, rest} = :gb_sets.take_smallest(pending)
        {recv, id, pkt} = entry
        st = dispatch(%{st | pending: rest}, id, pkt, recv)
        drain(st, actors, rest, now)
    end
  end

  defp dispatch(st, id, pkt, recv) do
    case Map.get(st.players, id) do
      nil ->
        pos = if pkt.type == :move, do: pkt.pos, else: st.map.spawn
        p = Player.new(id, pos, recv)
        st = %{st | players: :maps.put(id, p, st.players)}
        dispatch_existing(st, id, pkt, recv)

      _ ->
        dispatch_existing(st, id, pkt, recv)
    end
  end

  defp dispatch_existing(st, id, %{type: :move} = pkt, recv) do
    p = :maps.get(id, st.players)
    {v, p2} = Validator.handle_move(st.map, st.rules, p, pkt, recv)
    st = %{st | players: :maps.put(id, p2, st.players)}

    per = :maps.get(id, st.stats.per)

    per = %{
      per
      | moves: per.moves + 1,
        move_rejected: per.move_rejected + b(v.accepted),
        violations: merge_v(per.violations, v.violations)
    }

    %{
      st
      | stats: %{st.stats | per: :maps.put(id, per, st.stats.per), packets: st.stats.packets + 1}
    }
  end

  defp dispatch_existing(st, id, %{type: :attack} = pkt, recv) do
    p = :maps.get(id, st.players)
    lookup = fn tid -> :maps.get(tid, st.players, nil) || :none end
    {v, p2} = Validator.handle_attack(st.map, st.rules, p, pkt, recv, lookup)
    st = %{st | players: :maps.put(id, p2, st.players)}

    per = :maps.get(id, st.stats.per)

    per = %{
      per
      | attacks: per.attacks + 1,
        attacks_rejected: per.attacks_rejected + b(v.accepted),
        violations: merge_v(per.violations, v.violations)
    }

    %{
      st
      | stats: %{st.stats | per: :maps.put(id, per, st.stats.per), packets: st.stats.packets + 1}
    }
  end

  # 1 when rejected (accepted=false)
  defp b(true), do: 0
  defp b(false), do: 1

  defp merge_v(acc, vs), do: Enum.reduce(vs, acc, fn v, m -> Map.update(m, v, 1, &(&1 + 1)) end)

  # ------------------------------------------------------------------
  # Report
  # ------------------------------------------------------------------

  defp report(st, actors, dt, ticks, elapsed_us) do
    rows =
      Enum.map(actors, fn a ->
        per = :maps.get(a.id, st.stats.per)
        pl = :maps.get(a.id, st.players, nil)

        %{
          id: a.id,
          profile: a.profile,
          cheat: a.profile != :honest,
          moves: per.moves,
          move_rejected: per.move_rejected,
          attacks: per.attacks,
          attacks_rejected: per.attacks_rejected,
          attacks_accepted: per.attacks - per.attacks_rejected,
          any_violation: map_size(per.violations) > 0,
          violations: per.violations,
          status: if(pl, do: pl.status, else: :ok),
          max_score: if(pl, do: pl.stats.max_score, else: 0.0)
        }
      end)

    honest = Enum.filter(rows, &(not &1.cheat))
    cheats = Enum.filter(rows, & &1.cheat)

    honest_moves = Enum.sum(Enum.map(honest, & &1.moves))
    honest_fp = Enum.sum(Enum.map(honest, & &1.move_rejected))

    by_profile =
      cheats
      |> Enum.group_by(& &1.profile)
      |> Enum.map(fn {prof, rs} ->
        %{
          profile: prof,
          actors: length(rs),
          detected_actors: Enum.count(rs, &(mv_det(&1) or atk_det(&1))),
          undetected_actors: Enum.count(rs, &(not (mv_det(&1) or atk_det(&1)))),
          watched: Enum.count(rs, &(&1.status in [:watch, :ban])),
          banned: Enum.count(rs, &(&1.status == :ban)),
          moves: Enum.sum(Enum.map(rs, & &1.moves)),
          move_rejected: Enum.sum(Enum.map(rs, & &1.move_rejected)),
          attacks: Enum.sum(Enum.map(rs, & &1.attacks)),
          attacks_rejected: Enum.sum(Enum.map(rs, & &1.attacks_rejected)),
          attacks_stolen: Enum.sum(Enum.map(rs, & &1.attacks_accepted)),
          violations: sum_violations(rs)
        }
      end)
      |> Enum.sort_by(& &1.profile)

    %{
      setup: %{
        actors: length(rows),
        honest: length(honest),
        cheats: length(cheats),
        seconds: ticks * dt / 1000,
        dt_ms: dt,
        packets: st.stats.packets
      },
      throughput: %{
        wall_seconds: Float.round(elapsed_us / 1_000_000, 2),
        packets_per_sec: round(st.stats.packets / max(elapsed_us / 1_000_000, 0.001)),
        us_per_packet: Float.round(elapsed_us / max(st.stats.packets, 1), 2)
      },
      honest: %{
        moves: honest_moves,
        false_positive_moves: honest_fp,
        false_positive_rate: ratio(honest_fp, honest_moves),
        actors_with_any_violation: Enum.count(honest, & &1.any_violation),
        actors_watched: Enum.count(honest, &(&1.status in [:watch, :ban])),
        actors_banned: Enum.count(honest, &(&1.status == :ban)),
        violations: sum_violations(honest)
      },
      cheats: %{
        actors: length(cheats),
        actors_detected: Enum.count(cheats, &(mv_det(&1) or atk_det(&1))),
        moves: Enum.sum(Enum.map(cheats, & &1.moves)),
        detected_moves: Enum.sum(Enum.map(cheats, & &1.move_rejected)),
        move_detection_rate:
          ratio(
            Enum.sum(Enum.map(cheats, & &1.move_rejected)),
            Enum.sum(Enum.map(cheats, & &1.moves))
          ),
        attacks: Enum.sum(Enum.map(cheats, & &1.attacks)),
        attacks_rejected: Enum.sum(Enum.map(cheats, & &1.attacks_rejected)),
        attacks_stolen: Enum.sum(Enum.map(cheats, & &1.attacks_accepted)),
        by_profile: by_profile
      },
      rows: rows
    }
  end

  defp mv_det(r), do: r.move_rejected > 0
  defp atk_det(r), do: r.attacks_rejected > 0

  defp sum_violations(rows) do
    Enum.reduce(rows, %{}, fn r, acc -> Map.merge(acc, r.violations, fn _k, a, b -> a + b end) end)
  end

  defp ratio(_n, 0), do: 0.0
  defp ratio(n, d), do: Float.round(n / d, 4)
end
