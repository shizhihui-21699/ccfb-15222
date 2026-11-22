defmodule Aegis.Validator do
  @moduledoc """
  Server-authoritative validation core. Pure functions, no IO:

      handle_move(map, rules, player, payload, now) -> {verdict, player}
      handle_attack(map, rules, player, payload, now, lookup) -> {verdict, player}
      handle_event(map, rules, player, event, now)   -> {verdict, player}
      handle_knockback(player, event, now)            -> player

  `now` is **server monotonic milliseconds**, never client-supplied. Client
  timestamps are only a timeline hint and are clamped.

  See `Aegis.Rules` for *why* latency and packet loss do not produce false
  positives. This module is the mechanics.
  """

  alias Aegis.{Map, Path, Player, Rules}

  @type now_ms :: integer()

  # ==================================================================
  # Movement
  # ==================================================================

  def handle_move(map, rules, %Player{} = p, payload, now) do
    p = decay_score(p, rules, now)

    cond do
      # The first *movement* report establishes the origin, but only within a
      # small radius of the spawn the server assigned. That absorbs packet
      # reordering around the join (so the first arrival need not be seq 1)
      # without letting a cheater use the join packet as a free teleport.
      p.last_seq == -1 and
          Map.dist(p.pos, normalize_pos(map, payload.pos)) <= rules.join_tolerance ->
        do_first_move(map, rules, p, payload, now)

      payload.seq > p.last_seq ->
        do_move(map, rules, p, payload, now)

      true ->
        {verdict(p, true, p.pos, false, [], :stale), p}
    end
  end

  # Seed the timeline from the first movement report without a distance check.
  defp do_first_move(map, rules, p, payload, now) do
    pos = normalize_pos(map, payload.pos)
    pos = if Map.walkable?(map, pos), do: pos, else: snap(map, pos, map.spawn)
    {p, portals, pos} = apply_arrival_portal(map, p, now, pos)
    ts = if is_integer(payload.client_ts), do: payload.client_ts, else: nil

    stats = %{p.stats | moves: p.stats.moves + 1, portals: p.stats.portals + length(portals)}
    bucket = if portals == [], do: 0.0, else: Rules.budget_cap(rules)

    p = %{
      p
      | pos: pos,
        last_seq: payload.seq,
        last_server_ms: now,
        last_client_ts: ts,
        origin_client_ts: ts || p.origin_client_ts,
        origin_server_ms: now,
        bucket: bucket,
        stats: stats
    }

    p = Player.push_history(p, now, pos)
    {verdict(p, true, pos, false, [], if(portals == [], do: :move, else: :portal)), p}
  end

  defp do_move(map, rules, p, payload, now) do
    target = normalize_pos(map, payload.pos)
    server_dt = max(now - p.last_server_ms, 0)

    {p, cdt, clock_viol} = timeline_step(p, rules, payload, now, server_dt)

    # Portal inference runs first. If the packet that would have reported the
    # player standing on a trigger was lost, the next report arrives at the
    # portal exit: a 100m+ displacement that no budget can cover, but which is
    # perfectly legal. We recognise it from geometry (last accepted position
    # near a trigger, new position at that portal's exit) rather than from a
    # client-supplied event.
    case infer_portal(map, p, target, now) do
      {:ok, portal} -> accept_portal(map, p, rules, payload, now, target, portal)
      :none -> do_move_budget(map, rules, p, payload, now, target, cdt, clock_viol, server_dt)
    end
  end

  defp do_move_budget(map, rules, p, payload, now, target, cdt, clock_viol, _server_dt) do
    {p, bucket} = refill_bucket(p, rules, cdt)

    # Compute budget BEFORE recording this move.
    ccap = Rules.window_cap(rules)
    scap = Rules.server_window_cap(rules)
    {p, csum} = evict_client(p, payload, now, rules)
    {p, ssum} = evict_server(p, now, rules)
    client_remain = max(ccap - csum, 0.0)
    server_remain = max(scap - ssum, 0.0)

    dist = Map.dist(p.pos, target)
    {p, grant_used} = consume_grant(p, now, dist)
    budget_dist = max(dist - grant_used, 0.0)

    allowance = min(bucket, min(client_remain, server_remain)) + rules.packet_slack
    excess = budget_dist - allowance

    # Geometry is checked FIRST and is absolute: even a "legal speed" move that
    # crosses a wall is a wall breach. Budget only decides how far along the
    # requested move we let the player get when the move is otherwise sane.
    case check_geometry(map, rules, p.pos, target) do
      {:violation, g_kind, safe} ->
        # `check_geometry` only reports a violation when the move is not a
        # plausible detour - i.e. the straight line really breaches a wall.
        # Keep the specific `:wall` / `:wall_graze` signal, except for a single
        # enormous jump: that is an attempted teleport and should escalate as
        # one (this stops a cheat from hiding a blink inside a "wall graze").
        g_kind =
          if excess >= rules.teleport_excess and g_kind == :wall_graze,
            do: :teleport,
            else: g_kind

        # Wall / noclip. Stop at the furthest legal point along the segment that
        # the budget also allows (so a noclip teleport is also distance-capped).
        allowed_total = grant_used + max(min(allowance, Map.dist(p.pos, safe)), 0.0)
        corrected = snap(map, advance_toward(p.pos, target, allowed_total), p.pos)

        p = bump(p, rules, g_kind, now)
        p = Player.note_violation(p, g_kind)
        d = max(Map.dist(p.pos, corrected) - grant_used, 0.0)
        p = accept_move(map, p, rules, payload, now, corrected, d)
        {verdict(p, false, corrected, true, vios([clock_viol, g_kind]), :move), p}

      :clear when excess > 0.0 ->
        kind = if excess >= rules.teleport_excess, do: :teleport, else: :speed
        allowed_total = grant_used + max(allowance, 0.0)
        corrected = snap(map, advance_toward(p.pos, target, allowed_total), p.pos)

        p = bump(p, rules, kind, now)
        p = Player.note_violation(p, kind)
        d = max(Map.dist(p.pos, corrected) - grant_used, 0.0)
        p = accept_move(map, p, rules, payload, now, corrected, d)
        {verdict(p, false, corrected, true, vios([clock_viol, kind]), :move), p}

      :clear ->
        p = accept_move(map, p, rules, payload, now, target, budget_dist)
        # `p.pos` may differ from `target` if the move triggered a portal.
        {verdict(p, true, p.pos, false, vios([clock_viol]), :move), p}
    end
  end

  # ---- timeline ------------------------------------------------------

  defp timeline_step(p, rules, payload, now, server_dt) do
    ts = payload.client_ts

    cond do
      not is_integer(ts) ->
        {p, server_dt, nil}

      p.last_client_ts == nil ->
        # First timestamped packet: there is no prior client time to credit, so
        # it earns no displacement budget. (The caller seeded us at the spawn.)
        {%{p | last_client_ts: ts, origin_client_ts: ts, origin_server_ms: now}, 0, nil}

      true ->
        raw = ts - p.last_client_ts

        cond do
          raw < 0 ->
            # Out-of-order timestamp: no timeline credit for this packet.
            {p, 0, nil}

          raw > server_dt + rules.clock_slack_ms + rules.clock_slack_ratio * server_dt ->
            p = bump(p, rules, :clock, now)
            p = Player.note_violation(p, :clock)
            {%{p | last_client_ts: ts}, 0, :clock}

          true ->
            {%{p | last_client_ts: ts}, raw, nil}
        end
    end
  end

  # The per-packet bucket accrues from the client's own frame delta, so arrival
  # jitter (which only distorts wall-clock gaps) cannot starve it. It is capped
  # at the window capacity: a long stall can earn at most one window of travel.
  defp refill_bucket(p, rules, cdt) do
    cap = Rules.budget_cap(rules)
    bucket = min(p.bucket + cdt * Rules.eff_speed(rules) / 1000.0, cap)
    {%{p | bucket: bucket}, bucket}
  end

  # The client-timeline window is keyed on a virtual time that never runs ahead
  # of the real elapsed time by more than `max_clock_lead`.
  defp virtual_time(p, payload, now) do
    real_elapsed = now - p.origin_server_ms

    case {p.origin_client_ts, is_integer(payload.client_ts)} do
      {origin, true} when is_integer(origin) ->
        max(0, min(payload.client_ts - origin, real_elapsed + 800))

      _ ->
        real_elapsed
    end
  end

  defp evict_client(p, payload, now, rules) do
    vt = virtual_time(p, payload, now)
    {sum, q} = evict(p.cwin, vt - rules.win_ms)
    {%{p | cwin: {q, sum}}, sum}
  end

  defp evict_server(p, now, rules) do
    {sum, q} = evict(p.swin, now - rules.win_ms)
    {%{p | swin: {q, sum}}, sum}
  end

  defp accept_move(map, p, rules, payload, now, pos, dist, opts \\ []) do
    vt = virtual_time(p, payload, now)
    d = max(dist, 0.0)

    {csum, cq} = evict(p.cwin, vt - rules.win_ms)
    {ssum, sq} = evict(p.swin, now - rules.win_ms)

    cwin = {:queue.in({vt, d}, cq), csum + d}
    swin = {:queue.in({now, d}, sq), ssum + d}

    {p, portal_used, pos} = apply_arrival_portal(map, p, now, pos)
    used_portals = Keyword.get(opts, :portals, []) ++ portal_used

    # A portal resets the per-packet bucket: the jump is free, and the player's
    # next reports start from the exit with a full allowance.
    bucket = if portal_used == [], do: max(p.bucket - d, 0.0), else: Rules.budget_cap(rules)

    stats = %{
      p.stats
      | moves: p.stats.moves + 1,
        distance: p.stats.distance + d,
        portals: p.stats.portals + length(used_portals)
    }

    p = %{
      p
      | pos: pos,
        last_seq: payload.seq,
        last_server_ms: now,
        bucket: bucket,
        cwin: cwin,
        swin: swin,
        stats: stats
    }

    Player.push_history(p, now, pos)
  end

  # ---- geometry ------------------------------------------------------

  defp check_geometry(map, rules, from, to) do
    if Map.walkable?(map, from) and Map.walkable?(map, to) do
      case Map.sweep(map, from, to) do
        {:clear, _} ->
          :clear

        {:blocked, stop, blocked_len} ->
          direct = Map.dist(from, to)
          margin = Rules.wall_detour_margin(rules, direct)

          if Path.reachable?(map, from, to, direct + margin) do
            # Honest corner cut: a short detour exists.
            :clear
          else
            kind = if blocked_len >= rules.wall_penetration, do: :wall, else: :wall_graze
            {:violation, kind, snap(map, stop, from)}
          end
      end
    else
      cond do
        not Map.walkable?(map, to) ->
          case Map.nearest_walkable(map, to, 6.0) do
            {:ok, safe, d} when d <= rules.wall_penetration -> {:violation, :wall_graze, safe}
            {:ok, safe, _} -> {:violation, :wall, safe}
            :none -> {:violation, :wall, from}
          end

        true ->
          # Started inside geometry (shouldn't happen): recover silently.
          {:violation, :wall_graze, snap(map, from, map.spawn)}
      end
    end
  end

  # ---- portals -------------------------------------------------------

  # A report that lands on a trigger teleports the player immediately. This is
  # server-side: the client never sends a teleport event.
  defp apply_arrival_portal(map, p, now, pos) do
    case Map.portal_at(map, pos) do
      {:ok, portal} ->
        last = :maps.get(portal.id, p.portal_uses, -1_000_000_000)

        if now - last >= portal.cooldown_ms do
          # The jump itself is free (it is not player movement), and the player
          # emerges with a fresh per-packet bucket so their first steps out of
          # the exit are not billed against the pre-jump budget.
          p = %{
            p
            | portal_uses: :maps.put(portal.id, now, p.portal_uses),
              bucket: 0.0
          }

          {p, [portal.id], portal.exit}
        else
          {p, [], pos}
        end

      :none ->
        {p, [], pos}
    end
  end

  # The packet that would have reported the player standing on the trigger may
  # be lost. Then the next report arrives at (or past) the exit, which looks
  # like a 100m teleport. We recognise it from geometry alone: the reported
  # segment passed through a trigger, and the destination is at that portal's
  # exit. No client event is trusted.
  defp infer_portal(map, p, target, now) do
    Enum.find_value(map.portals, :none, fn portal ->
      last = :maps.get(portal.id, p.portal_uses, -1_000_000_000)
      {tx, ty, tr} = portal.trigger

      crossed =
        Map.dist(p.pos, {tx, ty}) <= tr + 0.5 or
          Map.dist(segment_point(p.pos, target, {tx, ty}), {tx, ty}) <= tr

      arrived = Map.dist(target, portal.exit) <= 6.0

      if now - last >= portal.cooldown_ms and crossed and arrived do
        {:ok, portal}
      end
    end)
  end

  defp segment_point({x0, y0}, {x1, y1}, {px, py}) do
    dx = x1 - x0
    dy = y1 - y0
    len2 = dx * dx + dy * dy

    if len2 == 0.0 do
      {x0, y0}
    else
      t = (((px - x0) * dx + (py - y0) * dy) / len2) |> max(0.0) |> min(1.0)
      {x0 + t * dx, y0 + t * dy}
    end
  end

  defp accept_portal(map, p, rules, payload, now, target, portal) do
    jump = max(Map.dist(p.pos, target), 0.0)
    p = %{p | portal_uses: :maps.put(portal.id, now, p.portal_uses)}

    p = accept_move(map, p, rules, payload, now, target, jump, portals: [portal.id])
    {verdict(p, true, p.pos, false, [], :portal), p}
  end

  # ---- grants --------------------------------------------------------

  defp consume_grant(p, now, dist) do
    cond do
      p.grant <= 0.0 ->
        {p, 0.0}

      now > p.grant_expires ->
        {%{p | grant: 0.0}, 0.0}

      true ->
        used = min(p.grant, dist)
        {%{p | grant: p.grant - used}, used}
    end
  end

  @doc """
  Apply a server-initiated knockback. The resulting displacement will arrive
  back through the client's normal reports, so it is credited as a grant.
  """
  def handle_knockback(%Player{} = p, %{impulse: meters}, now) do
    p = grant(p, now, meters, 1_500)
    %{p | stats: %{p.stats | knockbacks: p.stats.knockbacks + 1}}
  end

  defp grant(p, now, meters, ttl) do
    %{p | grant: p.grant + meters, grant_expires: max(p.grant_expires, now + ttl)}
  end

  # ==================================================================
  # Combat
  # ==================================================================

  @doc """
  Validate an attack. `lookup.(target_id)` returns `%Player{}` or `:none`.

  The attacker's position is authoritative (current or any position it held in
  the rewind window). The victim reference is a history sample, picked using the
  claimed position only as a hint. Line of sight is checked to that sample.
  """
  def handle_attack(map, rules, %Player{} = p, payload, now, lookup) do
    p = decay_score(p, rules, now)
    w = rules.weapon
    {p, rate_ok} = take_attack_token(p, rules, now, payload)
    p = %{p | stats: %{p.stats | attacks: p.stats.attacks + 1}}

    cond do
      not rate_ok ->
        p = bump(p, rules, :attack_rate, now)
        p = Player.note_violation(p, :attack_rate)
        p = reject_stat(p)
        {verdict(p, false, p.pos, true, [:attack_rate], :attack), p}

      true ->
        case lookup.(payload.target) do
          :none ->
            p = reject_stat(p)
            {verdict(p, false, p.pos, true, [], :attack), p}

          %Player{} = victim ->
            validate_hit(map, rules, p, payload, now, victim, w)
        end
    end
  end

  defp validate_hit(map, rules, p, payload, now, victim, w) do
    recent = Player.recent_positions(victim, now, w.rewind_ms)
    victim_ref = reference_point(recent, payload.victim_pos, victim.pos)

    accepted = [p.pos | Enum.map(Player.recent_positions(p, now, w.rewind_ms), &elem(&1, 1))]

    # The client knows where it was when it fired. An attack packet can arrive
    # before the move packet that put the attacker there (UDP reordering), in
    # which case the server's accepted positions are all stale. Accept the
    # claimed origin only when it is close to an accepted position AND does not
    # get the attacker any closer to the victim than the best accepted position
    # already does - so it fixes reordering but cannot be used to gain reach.
    best_accepted_dist = Enum.min(Enum.map(accepted, &Map.dist(&1, victim_ref)))
    claimed = :maps.get(:attacker_pos, payload, nil)

    claimed_origin =
      case claimed do
        {x, y} when is_number(x) and is_number(y) ->
          pos = {x * 1.0, y * 1.0}

          near? = Enum.any?(accepted, fn ap -> Map.dist(ap, pos) <= w.max_origin_drift end)
          no_gain? = Map.dist(pos, victim_ref) >= best_accepted_dist - w.max_origin_drift

          if near? and no_gain?, do: [pos], else: []

        _ ->
          []
      end

    attacker_candidates = Enum.uniq(accepted ++ claimed_origin)

    hit =
      Enum.any?(attacker_candidates, fn apos ->
        Map.dist(apos, victim_ref) <= w.range + w.range_tolerance and
          Map.line_of_sight?(map, apos, victim_ref)
      end)

    if hit do
      p = %{p | score: decay(p, rules, now), score_t: now}
      p = promote(p, rules)

      p = %{
        p
        | stats: %{
            p.stats
            | attacks_accepted: p.stats.attacks_accepted + 1,
              hits: p.stats.hits + 1
          }
      }

      {verdict(p, true, p.pos, false, [], :attack), p}
    else
      p = bump(p, rules, :attack_range, now)
      p = Player.note_violation(p, :attack_range)
      p = reject_stat(p)
      {verdict(p, false, p.pos, true, [:attack_range], :attack), p}
    end
  end

  defp reject_stat(p),
    do: %{p | stats: %{p.stats | attacks_rejected: p.stats.attacks_rejected + 1}}

  defp reference_point([], _claimed, current), do: current

  defp reference_point(recent, claimed, current) do
    if is_tuple(claimed) do
      recent
      |> Enum.map(fn {_t, pos} -> {pos, Map.dist2(pos, claimed)} end)
      |> Enum.min_by(&elem(&1, 1))
      |> elem(0)
    else
      current
    end
  end

  # Attack rate uses the client timeline where available (jitter-immune), with a
  # real-time token bucket as the backstop against a forged clock.
  defp take_attack_token(p, rules, now, payload) do
    w = rules.weapon
    client_ts = :maps.get(:client_ts, payload, nil)
    key = if is_integer(client_ts), do: max(client_ts, p.rate[:t] || 0), else: now
    t0 = p.rate[:t] || key - 10_000
    elapsed = max(key - t0, 0)
    tokens = min(p.rate.tokens + elapsed / w.cooldown_ms, w.rate_burst)

    # server wall-clock backstop: at most burst-per-window arrivals
    window = Enum.filter(p.attack_window, &(&1 >= now - w.cooldown_ms * 6))
    per_window = 6

    if tokens >= 1.0 and length(window) < per_window do
      {%{p | rate: %{tokens: tokens - 1.0, t: key}, attack_window: [now | window]}, true}
    else
      {%{p | rate: %{tokens: tokens, t: key}, attack_window: window}, false}
    end
  end

  # ==================================================================
  # Hijacked events
  # ==================================================================

  @doc "A client may never teleport itself."
  def handle_event(_map, rules, %Player{} = p, %{type: :client_teleport}, now) do
    p = bump(p, rules, :event_hijack, now)
    p = Player.note_violation(p, :event_hijack)
    {verdict(p, false, p.pos, true, [:event_hijack], :event), p}
  end

  # ==================================================================
  # Scoring
  # ==================================================================

  defp decay_score(%Player{} = p, rules, now) do
    score = decay(p, rules, now)
    p = %{p | score: score, score_t: now}

    case p.status do
      :watch when score < rules.watch_score -> %{p | status: :ok}
      _ -> p
    end
  end

  defp bump(p, rules, kind, now) do
    score = decay(p, rules, now) + :maps.get(kind, rules.weights, 1.0)

    p = %{
      p
      | score: score,
        score_t: now,
        stats: %{p.stats | max_score: max(p.stats.max_score, score)}
    }

    promote(p, rules)
  end

  defp promote(%Player{status: :ban} = p, _rules), do: p

  defp promote(p, rules) do
    cond do
      p.score >= rules.ban_score -> %{p | status: :ban}
      p.score >= rules.watch_score and p.status == :ok -> %{p | status: :watch}
      true -> p
    end
  end

  defp decay(%Player{} = p, rules, now) do
    dt = max(now - p.score_t, 0)
    p.score * :math.pow(0.5, dt / rules.half_life_ms)
  end

  # ==================================================================
  # Helpers
  # ==================================================================

  defp verdict(p, accepted, pos, corrected, vios, action) do
    %{
      accepted: accepted,
      pos: pos,
      corrected: corrected,
      violations: vios,
      score: p.score,
      status: p.status,
      action: action
    }
  end

  defp vios(list), do: list |> Enum.reject(&is_nil/1) |> Enum.uniq()

  defp evict({q, sum}, cutoff) do
    case :queue.out(q) do
      {{:value, {key, d}}, q2} when key < cutoff ->
        evict({q2, max(sum - d, 0.0)}, cutoff)

      _ ->
        {sum, q}
    end
  end

  defp advance_toward(from, to, max_dist) do
    d = Map.dist(from, to)

    cond do
      d == 0.0 -> from
      max_dist >= d -> to
      max_dist <= 0.0 -> from
      true -> Map.point_at(from, to, max_dist / d)
    end
  end

  defp normalize_pos(map, pos) do
    case pos do
      {x, y} when is_number(x) and is_number(y) -> {x * 1.0, y * 1.0}
      _ -> map.spawn
    end
  end

  defp snap(map, pos, fallback) do
    if Map.walkable?(map, pos) do
      pos
    else
      case Map.nearest_walkable(map, pos, 6.0) do
        {:ok, p, _} -> p
        :none -> fallback
      end
    end
  end
end
