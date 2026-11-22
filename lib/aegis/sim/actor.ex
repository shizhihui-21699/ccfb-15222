defmodule Aegis.Sim.Actor do
  @moduledoc """
  A synthetic client with a **true** position (what the simulation moves) and a
  **profile** that decides what it reports.

  Profiles model what real cheat software does, not strawmen:

    * `:honest`        - truthful, respects cooldown/range/LOS.
    * `:speed`         - walks `factor`x legal speed, reports truthfully.
    * `:teleport`      - blinks to a random far point every few seconds.
    * `:noclip`        - walks straight through walls.
    * `:aimbot_range`  - attacks targets out of range.
    * `:aimbot_wall`   - attacks targets through walls.
    * `:spin`          - fires every tick (way past cooldown).
    * `:flash`         - teleports + out-of-range + through-wall attacks.

  An honest actor's corrections are **false positives**; a cheat's accepted
  attacks are **false negatives**. Both are counted by the runner.
  """

  defstruct [
    :id,
    :profile,
    :speed,
    :pos,
    :route,
    :route_i,
    :rng,
    :move_seq,
    :atk_seq,
    :next_attack_ms,
    :last_teleport_ms,
    started: false,
    portal_uses: %{},
    profile_opts: %{}
  ]

  @type t :: %__MODULE__{}

  def new(id, profile, map, opts) do
    speed = Keyword.fetch!(opts, :speed)
    dt = Keyword.fetch!(opts, :dt_ms)
    rng = Aegis.Sim.Net.seeded(Keyword.fetch!(opts, :seed))
    # a speed cheat moves faster, so its *true* route must be faster too;
    # otherwise the route spacing itself would cap its reported speed.
    eff_speed = if profile == :speed, do: speed * factor(opts), else: speed

    {route, rng} = Aegis.Sim.Route.random(map, eff_speed, dt, rng, tries: 10)
    start = hd(route.points)

    # noclip starts inside the wall's near face so it breaches on the first move
    {start, profile_opts} =
      case profile do
        :noclip ->
          po = Keyword.get(opts, :profile_opts, %{}) || %{}
          home = Map.get(po, :noclip_home, start)
          {home, Map.put(po, :noclip_home, home)}

        _ ->
          {start, Keyword.get(opts, :profile_opts, %{}) || %{}}
      end

    %__MODULE__{
      id: id,
      profile: profile,
      speed: eff_speed,
      pos: start,
      route: route,
      route_i: 0,
      rng: rng,
      move_seq: 0,
      atk_seq: 0,
      next_attack_ms: 0,
      last_teleport_ms: 0,
      profile_opts: profile_opts
    }
  end

  defp factor(opts) do
    case Keyword.get(opts, :profile_opts, %{}) do
      %{factor: f} -> f
      _ -> 2.0
    end
  end

  @doc """
  Advance one tick at client time `t`. `ctx` is
  `%{map, targets: [{id, pos}], weapon_range, dt_ms}`.
  """
  def step(%__MODULE__{} = a, t, ctx) do
    a = advance_true(a, t)
    {a, m} = move_report(a, t, ctx)
    {a, atk} = attack_report(a, t, ctx)
    {a, m ++ atk}
  end

  # The first tick reports the spawn point itself; every later tick advances
  # one route point. This mirrors a client that connects at its spawn.
  defp advance_true(%{started: false} = a, _t), do: %{a | started: true}

  defp advance_true(a, t) do
    points = a.route.points
    next_i = a.route_i + 1

    pos =
      if next_i < length(points) do
        Enum.at(points, next_i)
      else
        a.pos
      end

    # A real client that walks onto a portal is teleported by its own client
    # prediction; the simulator must do the same or it would keep reporting a
    # track that diverges from the server's portal jump.
    {a, pos} = apply_portal(%{a | pos: pos}, pos, t)
    %{a | pos: pos, route_i: next_i}
  end

  defp apply_portal(a, pos, t) do
    case Aegis.Map.portal_at(:persistent_term.get(:aegis_map), pos) do
      {:ok, portal} ->
        last = :maps.get(portal.id, a.portal_uses, -1_000_000)

        if t - last >= portal.cooldown_ms do
          {%{a | portal_uses: :maps.put(portal.id, t, a.portal_uses)}, portal.exit}
        else
          {a, pos}
        end

      :none ->
        {a, pos}
    end
  end

  # ---- movement ------------------------------------------------------

  defp move_report(%{profile: p} = a, t, _ctx) when p in [:honest, :speed, :spin] do
    {a, [move(a, a.pos, t)]}
  end

  # Range/wall aim bots stay put and shoot targets they should not be able to
  # reach. (An aim bot that closes distance and then fires inside range is just
  # a legal player; there is nothing for the server to reject.)
  defp move_report(%{profile: p} = a, t, _ctx) when p in [:aimbot_range, :aimbot_wall] do
    {a, [move(a, a.pos, t)]}
  end

  # Noclip walks straight through geometry toward a fixed point. It starts on
  # the near side of a wall and its target is directly behind that wall, so the
  # wall is crossed almost immediately and repeatedly as it bounces back.
  defp move_report(%{profile: :noclip} = a, t, ctx) do
    target = Map.get(a.profile_opts, :noclip_target, {100.0, 70.0})
    step = a.speed * ctx.dt_ms / 1000.0
    {ax, ay} = a.pos
    {tx, ty} = target
    d = :math.sqrt((tx - ax) * (tx - ax) + (ty - ay) * (ty - ay))

    # bounce between the start and the target so the wall is crossed often
    a =
      if d <= step do
        %{a | pos: Map.get(a.profile_opts, :noclip_home, a.pos)}
      else
        %{a | pos: {ax + (tx - ax) / d * step, ay + (ty - ay) / d * step}}
      end

    {a, [move(a, a.pos, t)]}
  end

  defp move_report(%{profile: p} = a, t, ctx) when p in [:teleport, :flash] do
    interval = Map.get(a.profile_opts, :teleport_ms, 4_000)

    if t - a.last_teleport_ms >= interval do
      {dest, rng} = Aegis.Sim.Route.random_point(ctx.map, a.rng)
      a = %{a | rng: rng, last_teleport_ms: t, pos: dest}
      {a, [move(a, dest, t)]}
    else
      {a, [move(a, a.pos, t)]}
    end
  end

  defp move(a, pos, t), do: %{type: :move, seq: a.move_seq + 1, pos: pos, client_ts: t}

  # ---- attacks -------------------------------------------------------

  defp attack_report(%{profile: :spin} = a, t, ctx) do
    if rem(trunc(t), ctx.dt_ms) == 0 do
      case pick_target(a, ctx) do
        nil -> {a, []}
        {tid, vpos} -> {a, [attack(a, tid, vpos, t)]}
      end
    else
      {a, []}
    end
  end

  defp attack_report(%{profile: p} = a, t, ctx)
       when p in [:honest, :speed, :teleport, :noclip, :aimbot_range, :aimbot_wall, :flash] do
    cooldown = Map.get(a.profile_opts, :cooldown, 600)

    cond do
      t < a.next_attack_ms ->
        {a, []}

      true ->
        case pick_target(a, ctx) do
          nil ->
            {a, []}

          {tid, vpos} ->
            if hit_fun(p).(vpos, a, ctx) do
              {%{a | next_attack_ms: t + cooldown}, [attack(a, tid, vpos, t)]}
            else
              {a, []}
            end
        end
    end
  end

  defp hit_fun(:honest), do: &honest_hit/3
  defp hit_fun(:speed), do: &honest_hit/3
  defp hit_fun(:teleport), do: &honest_hit/3
  defp hit_fun(:noclip), do: &honest_hit/3

  defp hit_fun(:aimbot_range),
    do: fn v, a, c -> is_tuple(v) and Aegis.Map.dist(a.pos, v) > c.weapon_range end

  defp hit_fun(:aimbot_wall), do: &wall_only_hit/3

  defp hit_fun(:flash) do
    fn v, a, c ->
      is_tuple(v) and
        (Aegis.Map.dist(a.pos, v) > c.weapon_range or
           not Aegis.Map.line_of_sight?(c.map, a.pos, v))
    end
  end

  defp honest_hit(v, a, c) do
    is_tuple(v) and Aegis.Map.dist(a.pos, v) <= c.weapon_range and
      Aegis.Map.line_of_sight?(c.map, a.pos, v)
  end

  defp wall_only_hit(v, a, c) do
    is_tuple(v) and not Aegis.Map.line_of_sight?(c.map, a.pos, v)
  end

  defp pick_target(%{profile: :aimbot_range} = a, ctx) do
    # farthest target guarantees an out-of-range shot
    candidates =
      ctx.targets
      |> Enum.reject(fn {id, _} -> id == a.id end)
      |> Enum.map(fn {id, pos} -> {id, pos, Aegis.Map.dist(a.pos, pos)} end)
      |> Enum.filter(fn {_id, _pos, d} -> d > ctx.weapon_range end)
      |> Enum.sort_by(&elem(&1, 2), :desc)

    case candidates do
      [] -> nil
      [{id, pos, _} | _] -> {id, pos}
    end
  end

  defp pick_target(%{profile: :aimbot_wall} = a, ctx) do
    candidates =
      ctx.targets
      |> Enum.reject(fn {id, _} -> id == a.id end)
      |> Enum.filter(fn {_id, pos} -> not Aegis.Map.line_of_sight?(ctx.map, a.pos, pos) end)

    case candidates do
      [] -> nil
      [{id, pos} | _] -> {id, pos}
    end
  end

  defp pick_target(a, ctx) do
    ctx.targets
    |> Enum.reject(fn {id, _} -> id == a.id end)
    |> Enum.map(fn {id, pos} -> {id, pos, Aegis.Map.dist(a.pos, pos)} end)
    |> Enum.sort_by(&elem(&1, 2))
    |> case do
      [] -> nil
      [{id, pos, _} | _] -> {id, pos}
    end
  end

  defp attack(a, target, victim_pos, t) do
    %{
      type: :attack,
      seq: a.atk_seq + 1,
      target: target,
      victim_pos: victim_pos,
      attacker_pos: a.pos,
      client_ts: t
    }
  end

  @doc "Bump the packet counters after the runner has acknowledged the packets."
  def ack(a, packets) do
    Enum.reduce(packets, a, fn
      %{type: :move, seq: s}, a -> %{a | move_seq: max(a.move_seq, s)}
      %{type: :attack, seq: s}, a -> %{a | atk_seq: max(a.atk_seq, s)}
      _, a -> a
    end)
  end
end
