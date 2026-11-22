defmodule Aegis.ValidatorTest do
  use ExUnit.Case, async: true

  alias Aegis.{Map, Player, Rules, Validator}

  setup_all do
    map = Aegis.Map.Canyon.build()
    rules = Rules.new()
    {:ok, map: map, rules: rules}
  end

  @open {100.0, 70.0}

  defp player(pos \\ @open, now \\ 0), do: Player.new(:p1, pos, now)

  # Resample a polyline into points roughly `spacing` metres apart.
  defp interpolate(points, spacing) do
    points
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.flat_map(fn [a, b] ->
      n = max(1, ceil(Map.dist(a, b) / spacing))
      for i <- 1..n, do: Map.point_at(a, b, i / n)
    end)
  end

  # Drive a sequence of positions through the validator on a fixed cadence.
  # Positions are either a point or a `fn prev_pos -> point end`.
  defp drive(map, rules, p, positions, now0, ts0, dt_ms, gap_fn \\ nil) do
    Enum.reduce(positions, {p, now0, ts0, []}, fn step, {p, now, ts, vs} ->
      ts = ts + dt_ms
      now = now + if gap_fn, do: gap_fn.(ts), else: dt_ms
      pos = if is_function(step), do: step.(p.pos), else: step

      {v, p} =
        Validator.handle_move(map, rules, p, %{seq: p.last_seq + 1, pos: pos, client_ts: ts}, now)

      {p, now, ts, [v | vs]}
    end)
    |> then(fn {p, now, ts, vs} -> {p, now, ts, Enum.reverse(vs)} end)
  end

  # ==================================================================
  # Honest movement
  # ==================================================================

  describe "honest movement" do
    test "walking at max speed is always accepted", %{map: map, rules: rules} do
      step = 6.6 * 0.05
      positions = for i <- 1..39, do: {100.0 + step * i, 70.0}
      {p, _now, _ts, vs} = drive(map, rules, player(), positions, 0, 0, 50)

      assert Enum.all?(vs, & &1.accepted), inspect(Enum.filter(vs, &(not &1.accepted)))
      assert p.status == :ok
    end

    test "arrival jitter (0-300ms) does not trigger anything", %{map: map, rules: rules} do
      # Client advances 50ms per packet; packets arrive with very uneven gaps.
      step = 6.6 * 0.05
      positions = for i <- 1..119, do: {100.0 + step * i, 70.0}

      gap = fn _ts ->
        # deterministic pseudo-jitter 10..300ms
        :rand.seed(:exsss, {1, 2, 3})
        10 + :rand.uniform(290)
      end

      {p, _now, _ts, vs} = drive(map, rules, player(), positions, 0, 0, 50, gap)

      assert Enum.all?(vs, & &1.accepted),
             "jitter alone must never correct a move: #{inspect(Enum.filter(vs, &(not &1.accepted)) |> Enum.take(2))}"

      assert p.status == :ok
      assert map_size(p.stats.violations) == 0
    end

    test "packet loss: a long gap earns budget and is accepted", %{map: map, rules: rules} do
      # 1s with no packets, client moved 6.6m — legal speed over that time.
      positions = [{100.0, 70.0}, {106.6, 70.0}]
      {_p, _now, _ts, vs} = drive(map, rules, player(), positions, 0, 0, 1_000)
      assert Enum.at(vs, 1).accepted
    end

    test "cutting a corner (reported chord grazes a wall, real path short) is accepted",
         %{map: map, rules: rules} do
      # An honest client walks around the tip of the vertical wall, but its
      # 20 Hz position reports don't line up with the corner, so a reported
      # chord between two legal points grazes the wall. Only the *endpoints* of
      # each report are what the client claims; the segment is just the shortest
      # path the server can infer. This must not be a wall violation.
      start = {98.0, 54.0}
      target = {104.0, 58.0}

      # Legal detour from the grid path, then interpolated at 20 Hz so the
      # reported speed is honest; this recreates a client whose reports cut the
      # corner geometrically.
      {:ok, path} = Aegis.Path.find(map, start, target, max_len: 20)
      steps = interpolate([start | path], 0.33)
      {p, _now, _ts, vs} = drive(map, rules, player(start), steps, 0, 0, 50)

      corrected = Enum.filter(vs, & &1.corrected)

      assert corrected == [],
             "honest corner cut must not be corrected: #{inspect(Enum.take(corrected, 3))}"

      assert p.status == :ok
    end

    test "walking through a narrow door is accepted", %{map: map, rules: rules} do
      # Door gap in the {20,20,60,22} wall is around x=61..69.
      steps = for i <- 1..60, do: {65.0, 16.0 + i * 0.2}
      {p, _now, _ts, vs} = drive(map, rules, player({65.0, 16.0}), steps, 0, 0, 50)

      assert Enum.all?(vs, & &1.accepted),
             "door walk: #{inspect(Enum.filter(vs, &(not &1.accepted)))}"

      assert p.status == :ok
    end

    test "walking past a portal trigger without reaching it is normal", %{map: map, rules: rules} do
      # Portal trigger at {34,34} r=3. Walk from {34,45} towards {34,40}.
      steps = for i <- 1..50, do: {34.0, 45.0 - i * 0.1}
      {p, _now, _ts, vs} = drive(map, rules, player({34.0, 45.0}), steps, 0, 0, 50)
      assert Enum.all?(vs, & &1.accepted)
      assert p.stats.portals == 0
    end
  end

  # ==================================================================
  # Teleport
  # ==================================================================

  describe "teleport cheat" do
    test "a single large jump is rejected and corrected to nearby ground",
         %{map: map, rules: rules} do
      {v, _p2} =
        Validator.handle_move(
          map,
          rules,
          player(),
          %{seq: 1, pos: {180.0, 60.0}, client_ts: 50},
          50
        )

      refute v.accepted
      assert v.corrected
      assert :teleport in v.violations
      # correction keeps at most one bucket of travel from the origin
      assert Map.dist(@open, v.pos) <= Rules.budget_cap(rules) + 0.5
    end

    test "repeated teleports escalate to a ban", %{map: map, rules: rules} do
      positions = for _ <- 1..10, do: {180.0, 60.0}
      {p, _now, _ts, vs} = drive(map, rules, player(), positions, 0, 0, 50)

      assert Enum.all?(vs, &(not &1.accepted))
      assert p.status == :ban
      assert p.stats.violations[:teleport] >= 5
    end

    test "teleporting into a wall is corrected to a walkable point", %{map: map, rules: rules} do
      assert not Map.walkable?(map, {101.0, 40.0})

      {v, _p} =
        Validator.handle_move(
          map,
          rules,
          player(),
          %{seq: 1, pos: {101.0, 40.0}, client_ts: 50},
          50
        )

      refute v.accepted

      assert Map.walkable?(map, v.pos),
             "correction must land on walkable ground: #{inspect(v.pos)}"
    end
  end

  # ==================================================================
  # Speed
  # ==================================================================

  describe "speed hack" do
    test "moving at 2x speed is corrected within a second", %{map: map, rules: rules} do
      step = 6.6 * 2 * 0.05
      positions = for i <- 1..39, do: {100.0 + step * i, 70.0}
      {p, _now, _ts, vs} = drive(map, rules, player(), positions, 0, 0, 50)

      assert Enum.count(vs, & &1.corrected) > 0, "2x speed must be detected"
      assert p.status in [:watch, :ban]
    end

    test "moving inside the speed tolerance is not punished", %{map: map, rules: rules} do
      # 5% above nominal max speed is inside the 10% headroom.
      step = 6.6 * 1.05 * 0.05
      positions = for i <- 1..79, do: {100.0 + step * i, 70.0}
      {p, _now, _ts, vs} = drive(map, rules, player(), positions, 0, 0, 50)

      assert Enum.all?(vs, & &1.accepted)
      assert p.status == :ok
    end

    test "sustained 1.25x speed is caught", %{map: map, rules: rules} do
      step = 6.6 * 1.25 * 0.05
      positions = for i <- 1..79, do: {100.0 + step * i, 70.0}
      {p, _now, _ts, vs} = drive(map, rules, player(), positions, 0, 0, 50)

      assert Enum.count(vs, & &1.corrected) > 0
      assert p.status in [:watch, :ban]
    end

    test "forged client clock cannot buy speed", %{map: map, rules: rules} do
      # 4x speed, and the client also advances its clock 4x to "pay" for it.
      step = 6.6 * 4 * 0.05
      positions = for i <- 1..39, do: {100.0 + step * i, 70.0}

      {p, _now, _ts, vs} =
        Enum.reduce(positions, {player(), 0, 0, []}, fn pos, {p, now, ts, vs} ->
          now = now + 50
          ts = ts + 200

          {v, p} =
            Validator.handle_move(
              map,
              rules,
              p,
              %{seq: p.last_seq + 1, pos: pos, client_ts: ts},
              now
            )

          {p, now, ts, [v | vs]}
        end)

      assert Enum.count(vs, & &1.corrected) > 0
      assert p.stats.violations[:clock] > 0
      assert p.status in [:watch, :ban]
    end
  end

  # ==================================================================
  # Walls
  # ==================================================================

  describe "wall / noclip hack" do
    test "stepping across the thin vertical wall is rejected", %{map: map, rules: rules} do
      # Thin wall {100,30,102,56}: {98,40} and {104,40} are on opposite sides
      # but unreachable within a legal detour.
      assert not Aegis.Path.reachable?(map, {98.0, 40.0}, {106.0, 40.0}, 12.0)

      {v, p} =
        Validator.handle_move(
          map,
          rules,
          player({98.0, 40.0}),
          %{seq: 1, pos: {106.0, 40.0}, client_ts: 1_500},
          1_500
        )

      refute v.accepted
      # crossing sealed geometry is a wall breach (or, at this distance, a
      # teleport); either way it must be rejected.
      assert Enum.any?(v.violations, &(&1 in [:wall, :wall_graze, :teleport]))
      assert p.status in [:ok, :watch, :ban]
    end

    test "shooting through a wall is rejected by line of sight", %{map: map, rules: rules} do
      shooter = player({98.0, 40.0}, 0)
      victim = Player.new(:p2, {106.0, 40.0}, 0)

      lookup = fn
        :p2 -> victim
        _ -> :none
      end

      {v, _p} =
        Validator.handle_attack(
          map,
          rules,
          shooter,
          %{target: :p2, victim_pos: {106.0, 40.0}},
          50,
          lookup
        )

      refute v.accepted
      assert :attack_range in v.violations
    end
  end

  # ==================================================================
  # Attack range / rate
  # ==================================================================

  describe "attack range hack" do
    test "shooting far beyond weapon range is rejected", %{map: map, rules: rules} do
      shooter = player({20.0, 40.0}, 0)
      victim = Player.new(:p2, {80.0, 40.0}, 0)

      lookup = fn
        :p2 -> victim
        _ -> :none
      end

      {v, _p} =
        Validator.handle_attack(
          map,
          rules,
          shooter,
          %{target: :p2, victim_pos: {80.0, 40.0}},
          50,
          lookup
        )

      refute v.accepted
      assert :attack_range in v.violations
    end

    test "forging the victim position does not buy range", %{map: map, rules: rules} do
      shooter = player({20.0, 40.0}, 0)
      victim = Player.new(:p2, {80.0, 40.0}, 0)

      lookup = fn
        :p2 -> victim
        _ -> :none
      end

      {v, _p} =
        Validator.handle_attack(
          map,
          rules,
          shooter,
          %{target: :p2, victim_pos: {21.0, 40.0}},
          50,
          lookup
        )

      refute v.accepted
    end

    test "a legitimate in-range, in-sight shot is accepted", %{map: map, rules: rules} do
      shooter = player({100.0, 70.0}, 0)
      victim = Player.new(:p2, {108.0, 70.0}, 0)

      lookup = fn
        :p2 -> victim
        _ -> :none
      end

      {v, _p} =
        Validator.handle_attack(
          map,
          rules,
          shooter,
          %{target: :p2, victim_pos: {108.0, 70.0}},
          50,
          lookup
        )

      assert v.accepted
    end

    test "lag compensation: victim who turned the corner is still hit", %{map: map, rules: rules} do
      # Victim visible at t=0, behind the L-block by t=200. Attack arrives at
      # t=210 (within the 250ms rewind window).
      victim =
        Player.new(:p2, {86.0, 66.0}, 0)
        |> Player.push_history(0, {86.0, 66.0})
        |> Player.push_history(200, {92.0, 52.0})

      shooter = player({80.0, 68.0}, 0)

      lookup = fn
        :p2 -> victim
        _ -> :none
      end

      {v, _p} =
        Validator.handle_attack(
          map,
          rules,
          shooter,
          %{target: :p2, victim_pos: {86.0, 66.0}},
          210,
          lookup
        )

      assert v.accepted, "lag compensation should accept the shot: #{inspect(v.violations)}"
    end
  end

  describe "attack rate hack" do
    test "spamming attacks is rejected", %{map: map, rules: rules} do
      victim = Player.new(:p2, {104.0, 70.0}, 0)

      lookup = fn
        :p2 -> victim
        _ -> :none
      end

      {_p, vs} =
        Enum.reduce(1..10, {player(), []}, fn i, {p, vs} ->
          {v, p} =
            Validator.handle_attack(
              map,
              rules,
              p,
              %{target: :p2, victim_pos: {104.0, 70.0}, client_ts: i * 10},
              50,
              lookup
            )

          {p, [v | vs]}
        end)

      assert Enum.count(vs, &(not &1.accepted)) >= 6
    end
  end

  # ==================================================================
  # Portals / knockback
  # ==================================================================

  describe "portal and knockback" do
    test "walking into a portal teleports to the exit without a violation",
         %{map: map, rules: rules} do
      {v, p} =
        Validator.handle_move(
          map,
          rules,
          player({34.0, 34.0}),
          %{seq: 1, pos: {34.2, 34.0}, client_ts: 100},
          100
        )

      assert v.accepted
      assert v.pos == {166.0, 34.0}
      assert p.stats.portals == 1
      assert p.stats.violations == %{}
    end

    test "the packet right after a portal jump is not punished", %{map: map, rules: rules} do
      {_v, p} =
        Validator.handle_move(
          map,
          rules,
          player({34.0, 34.0}),
          %{seq: 1, pos: {34.2, 34.0}, client_ts: 100},
          100
        )

      # next report is at the exit — a 132m jump from the client's perspective
      {v2, p} =
        Validator.handle_move(map, rules, p, %{seq: 2, pos: {166.2, 34.0}, client_ts: 150}, 150)

      assert v2.accepted, inspect(v2.violations)
      assert p.status == :ok
    end

    test "lost trigger packet: next report at the exit is recognised, not flagged",
         %{map: map, rules: rules} do
      # Player walks onto the trigger; that packet is lost. The next report is
      # at the portal exit. Server must infer the portal from geometry.
      p = player({33.8, 34.0}, 0)

      {v, p} =
        Validator.handle_move(map, rules, p, %{seq: 2, pos: {166.0, 34.0}, client_ts: 400}, 400)

      assert v.accepted, "lost trigger packet must not be a teleport: #{inspect(v.violations)}"
      assert v.pos == {166.0, 34.0}
      assert p.stats.violations == %{}
    end

    test "a cheater cannot fake a portal jump from across the map", %{map: map, rules: rules} do
      # Never near a trigger, claims to be at the exit. Must be rejected.
      {v, p} =
        Validator.handle_move(
          map,
          rules,
          player({20.0, 20.0}),
          %{seq: 1, pos: {166.0, 34.0}, client_ts: 400},
          400
        )

      refute v.accepted
      assert :teleport in v.violations
    end

    test "portal cooldown prevents a second jump from the same report", %{map: map, rules: rules} do
      p = player({34.0, 34.0}, 0)

      {_v, p} =
        Validator.handle_move(map, rules, p, %{seq: 1, pos: {34.2, 34.0}, client_ts: 100}, 100)

      # Force the server position back onto the trigger as if the exit report
      # had been reordered; within the cooldown no jump may happen again.
      p = %{p | pos: {34.0, 34.0}}

      {v, _p} =
        Validator.handle_move(map, rules, p, %{seq: 2, pos: {34.1, 34.0}, client_ts: 300}, 300)

      assert v.pos == {34.1, 34.0}
    end

    test "walking normally after a portal is not punished", %{map: map, rules: rules} do
      {_v, p} =
        Validator.handle_move(
          map,
          rules,
          player({34.0, 34.0}),
          %{seq: 1, pos: {34.2, 34.0}, client_ts: 100},
          100
        )

      # Continue walking east from the exit at legal speed for a second.
      {p, _now, _ts, vs} =
        Enum.reduce(1..20, {p, 100, 100, []}, fn i, {p, now, ts, vs} ->
          now = now + 50
          ts = ts + 50
          pos = {166.0 + 0.33 * i, 34.0}

          {v, p} =
            Validator.handle_move(
              map,
              rules,
              p,
              %{seq: p.last_seq + 1, pos: pos, client_ts: ts},
              now
            )

          {p, now, ts, [v | vs]}
        end)

      assert Enum.all?(vs, & &1.accepted),
             "post-portal walking flagged: #{inspect(Enum.filter(vs, &(not &1.accepted)))}"

      assert p.status == :ok
    end

    test "knockback displacement is credited, not punished", %{map: map, rules: rules} do
      p = player({100.0, 70.0}, 0)
      p = Validator.handle_knockback(p, %{impulse: 8.0}, 10)

      {v, p} =
        Validator.handle_move(map, rules, p, %{seq: 1, pos: {100.0, 78.0}, client_ts: 50}, 50)

      assert v.accepted, "knockback must not be flagged: #{inspect(v.violations)}"
      assert p.status == :ok
    end
  end

  # ==================================================================
  # Events & scoring
  # ==================================================================

  describe "event hijack" do
    test "a client teleport event is rejected", %{map: map, rules: rules} do
      {v, p} = Validator.handle_event(map, rules, player(), %{type: :client_teleport}, 50)
      refute v.accepted
      assert :event_hijack in v.violations
      assert p.score >= rules.weights.event_hijack
    end
  end

  describe "score decay" do
    test "score decays over time and watch clears", %{map: map, rules: rules} do
      p = %{player() | score: 20.0, score_t: 0, status: :watch}
      # ~5 minutes later, one legal packet
      {v, p2} =
        Validator.handle_move(
          map,
          rules,
          p,
          %{seq: 1, pos: {100.01, 70.0}, client_ts: 300_000},
          300_000
        )

      assert v.accepted
      assert p2.score < 20.0
      assert p2.status == :ok
    end

    test "a flaky connection cannot accumulate a ban", %{map: map, rules: rules} do
      # 40 grazes (0.3 each) with honest walking in between; weights decay away.
      {p, _now, _ts, _vs} =
        Enum.reduce(1..40, {player(), 0, 0, []}, fn i, {p, now, ts, vs} ->
          now = now + 2_000
          ts = ts + 2_000
          pos = {100.0 + rem(i, 2) * 0.01, 70.0}

          {v, p} =
            Validator.handle_move(
              map,
              rules,
              p,
              %{seq: p.last_seq + 1, pos: pos, client_ts: ts},
              now
            )

          {p, now, ts, [v | vs]}
        end)

      assert p.status == :ok
    end
  end
end
