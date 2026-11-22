defmodule Aegis.Map do
  @moduledoc """
  Immutable, grid-based world geometry used by the server-authoritative
  movement validator.

  Everything here is read-only after construction and is meant to be kept in
  `:persistent_term` (see `install/2`), so every validation call is a plain
  function call with no ETS lookup and no process hop.

  Coordinates are meters. The world is `width x height` meters, rasterised
  into `cell x cell` meter cells. A cell is either walkable (0) or blocked (1).
  The border ring is always blocked, so a player can never leave the map.

  Walls are axis-aligned rectangles `{x0, y0, x1, y1}`. Only cells whose
  *centre* falls inside a rectangle are blocked.
  """

  @enforce_keys [:width, :height, :cell, :wc, :hc, :cells, :portals, :spawn]
  defstruct [:width, :height, :cell, :wc, :hc, :cells, :portals, :spawn, :name]

  @max_steps 4096
  @inf 1.0e30

  @type point :: {float(), float()}
  @type portal :: %{
          id: atom(),
          trigger: {float(), float(), float()},
          exit: point(),
          cooldown_ms: non_neg_integer(),
          label: String.t()
        }

  @type t :: %__MODULE__{}

  @doc """
  Build a map.

  Options:
    * `:width`, `:height` - meters
    * `:cell` - cell size in meters (default 2.0)
    * `:walls` - list of `{x0, y0, x1, y1}` rectangles
    * `:portals` - list of portal maps
    * `:spawn` - default spawn point
    * `:name` - atom used with `install/2`
  """
  def new(opts) do
    width = Keyword.fetch!(opts, :width)
    height = Keyword.fetch!(opts, :height)
    cell = Keyword.get(opts, :cell, 2.0)
    wc = ceil(width / cell)
    hc = ceil(height / cell)

    blocked =
      opts
      |> Keyword.get(:walls, [])
      |> Enum.reduce(MapSet.new(), fn {x0, y0, x1, y1}, acc ->
        rasterize_rect(acc, x0, y0, x1, y1, cell, wc, hc)
      end)

    blocked = add_border(blocked, wc, hc)

    cells =
      for cy <- 0..(hc - 1), into: <<>> do
        for cx <- 0..(wc - 1), into: <<>> do
          if MapSet.member?(blocked, cy * wc + cx), do: <<1>>, else: <<0>>
        end
      end

    portals =
      opts
      |> Keyword.get(:portals, [])
      |> Enum.map(fn p ->
        Map.merge(
          %{cooldown_ms: 0, label: to_string(p.id)},
          p
        )
      end)

    spawn = Keyword.get(opts, :spawn, {width / 2, height / 2})

    %__MODULE__{
      width: width * 1.0,
      height: height * 1.0,
      cell: cell * 1.0,
      wc: wc,
      hc: hc,
      cells: cells,
      portals: portals,
      spawn: spawn,
      name: Keyword.get(opts, :name, :default)
    }
  end

  @doc "Store the map (and rules) in `:persistent_term` for lock-free reads."
  def install(%__MODULE__{} = map, key \\ :aegis_map) do
    :persistent_term.put(key, map)
    map
  end

  def fetch(key \\ :aegis_map), do: :persistent_term.get(key)

  # ------------------------------------------------------------------
  # Queries
  # ------------------------------------------------------------------

  @doc "Is the point inside a walkable cell?"
  def walkable?(%__MODULE__{} = m, {x, y}) do
    cx = trunc(x / m.cell)
    cy = trunc(y / m.cell)

    cx >= 0 and cy >= 0 and cx < m.wc and cy < m.hc and
      :binary.at(m.cells, cy * m.wc + cx) == 0
  end

  @doc "Is a straight segment fully walkable?"
  def line_of_sight?(%__MODULE__{} = m, from, to), do: sweep(m, from, to) |> elem(0) == :clear

  @doc """
  Sweep a segment against the grid.

  Returns `{:clear, length}` or `{:blocked, stop_point, distance}` where
  `stop_point` is the last point on the segment before entering a blocked
  cell (i.e. where a server-authoritative correction should put the player).
  """
  def sweep(%__MODULE__{} = m, {x0, y0}, {x1, y1}) do
    dx = x1 - x0
    dy = y1 - y0
    len = :math.sqrt(dx * dx + dy * dy)

    cond do
      len == 0.0 ->
        if walkable?(m, {x0, y0}), do: {:clear, 0.0}, else: {:blocked, {x0, y0}, 0.0}

      true ->
        c = m.cell
        cx = clamp_i(trunc(x0 / c), 0, m.wc - 1)
        cy = clamp_i(trunc(y0 / c), 0, m.hc - 1)
        sx = sign(dx)
        sy = sign(dy)
        tdx = if dx == 0.0, do: @inf, else: abs(c / dx)
        tdy = if dy == 0.0, do: @inf, else: abs(c / dy)

        tmx =
          cond do
            dx == 0.0 -> @inf
            dx > 0.0 -> ((cx + 1) * c - x0) / dx
            true -> (cx * c - x0) / dx
          end

        tmy =
          cond do
            dy == 0.0 -> @inf
            dy > 0.0 -> ((cy + 1) * c - y0) / dy
            true -> (cy * c - y0) / dy
          end

        traverse(m, x0, y0, dx, dy, len, cx, cy, sx, sy, tmx, tmy, tdx, tdy, 0.0, 0)
    end
  end

  defp traverse(m, x0, y0, dx, dy, len, cx, cy, sx, sy, tmx, tmy, tdx, tdy, t_enter, steps) do
    cond do
      steps > @max_steps ->
        {:blocked, point_at(x0, y0, dx, dy, t_enter), max(t_enter, 0.0) * len}

      not cell_walkable?(m, cx, cy) ->
        {:blocked, point_at(x0, y0, dx, dy, t_enter), max(t_enter, 0.0) * len}

      true ->
        {t_next, cx, cy, sx, sy, tmx, tmy, tdx, tdy} =
          cond do
            tmx == tmy ->
              {tmx, cx + sx, cy + sy, sx, sy, tmx + tdx, tmy + tdy, tdx, tdy}

            tmx < tmy ->
              {tmx, cx + sx, cy, sx, sy, tmx + tdx, tmy, tdx, tdy}

            true ->
              {tmy, cx, cy + sy, sx, sy, tmx, tmy + tdy, tdx, tdy}
          end

        if t_next > 1.0 do
          # The rest of the segment stays inside the current (walkable) cell.
          {:clear, len}
        else
          traverse(
            m,
            x0,
            y0,
            dx,
            dy,
            len,
            cx,
            cy,
            sx,
            sy,
            tmx,
            tmy,
            tdx,
            tdy,
            t_next,
            steps + 1
          )
        end
    end
  end

  defp cell_walkable?(%__MODULE__{wc: wc, hc: hc, cells: cells}, cx, cy) do
    cx >= 0 and cy >= 0 and cx < wc and cy < hc and :binary.at(cells, cy * wc + cx) == 0
  end

  @doc """
  Returns the portal whose trigger contains `pos`, if any. When triggers
  overlap, the smallest radius wins (most specific).
  """
  def portal_at(%__MODULE__{portals: portals}, {x, y}) do
    portals
    |> Enum.reduce(nil, fn %{trigger: {px, py, r}} = p, best ->
      d2 = (px - x) * (px - x) + (py - y) * (py - y)

      cond do
        d2 > r * r -> best
        best == nil -> p
        r < elem(best.trigger, 2) -> p
        true -> best
      end
    end)
    |> case do
      nil -> :none
      p -> {:ok, p}
    end
  end

  def portal_by_id(%__MODULE__{portals: portals}, id), do: Enum.find(portals, &(&1.id == id))

  @doc "Clamp a point to the walkable interior (used for corrections / spawns)."
  def clamp_to_world(%__MODULE__{width: w, height: h, cell: c}, {x, y}) do
    {x |> max(c) |> min(w - c), y |> max(c) |> min(h - c)}
  end

  @doc """
  Nearest walkable cell centre to `pos`, searching up to `radius` meters.

  Returns `{:ok, point, distance}` or `:none`. Used to correct a position that
  was reported inside geometry.
  """
  def nearest_walkable(%__MODULE__{} = m, {x, y}, radius \\ 4.0) do
    c = m.cell
    cx = trunc(x / c)
    cy = trunc(y / c)
    span = ceil(radius / c)

    best =
      for dy <- -span..span, dx <- -span..span, reduce: nil do
        acc ->
          nx = cx + dx
          ny = cy + dy
          point = {nx * c + c / 2, ny * c + c / 2}
          d = dist({x, y}, point)

          cond do
            d > radius -> acc
            acc != nil and elem(acc, 2) <= d -> acc
            not cell_walkable?(m, nx, ny) -> acc
            true -> {:ok, point, d}
          end
      end

    best || :none
  end

  def walkable_cell?(%__MODULE__{} = m, cx, cy), do: cell_walkable?(m, cx, cy)

  @doc "A random walkable point, up to `tries` attempts."
  def random_walkable(%__MODULE__{} = m, rand, tries \\ 64) do
    x = rand.(m.width - 2 * m.cell) + m.cell
    y = rand.(m.height - 2 * m.cell) + m.cell

    cond do
      walkable?(m, {x, y}) -> {x, y}
      tries <= 1 -> m.spawn
      true -> random_walkable(m, rand, tries - 1)
    end
  end

  @doc "Point a fraction `t` (0..1) along the segment."
  def point_at({x0, y0}, {x1, y1}, t), do: {x0 + (x1 - x0) * t, y0 + (y1 - y0) * t}
  defp point_at(x0, y0, dx, dy, t), do: {x0 + dx * t, y0 + dy * t}

  @doc "Distance between two points."
  def dist({x0, y0}, {x1, y1}), do: :math.sqrt((x1 - x0) * (x1 - x0) + (y1 - y0) * (y1 - y0))

  def dist2({x0, y0}, {x1, y1}) do
    (x1 - x0) * (x1 - x0) + (y1 - y0) * (y1 - y0)
  end

  # ------------------------------------------------------------------
  # Construction helpers
  # ------------------------------------------------------------------

  defp rasterize_rect(acc, x0, y0, x1, y1, cell, wc, hc) do
    cx0 = max(trunc(x0 / cell), 0)
    cx1 = min(trunc(x1 / cell), wc - 1)
    cy0 = max(trunc(y0 / cell), 0)
    cy1 = min(trunc(y1 / cell), hc - 1)

    for cy <- cy0..cy1, cx <- cx0..cx1, reduce: acc do
      acc ->
        mx = (cx + 0.5) * cell
        my = (cy + 0.5) * cell

        if mx >= x0 and mx <= x1 and my >= y0 and my <= y1 do
          MapSet.put(acc, cy * wc + cx)
        else
          acc
        end
    end
  end

  defp add_border(acc, wc, hc) do
    acc =
      Enum.reduce(0..(wc - 1), acc, fn cx, a ->
        a |> MapSet.put(cx) |> MapSet.put((hc - 1) * wc + cx)
      end)

    Enum.reduce(0..(hc - 1), acc, fn cy, a ->
      a |> MapSet.put(cy * wc) |> MapSet.put(cy * wc + wc - 1)
    end)
  end

  defp sign(x) when x > 0.0, do: 1
  defp sign(x) when x < 0.0, do: -1
  defp sign(_), do: 0

  defp clamp_i(x, lo, _hi) when x < lo, do: lo
  defp clamp_i(x, _lo, hi) when x > hi, do: hi
  defp clamp_i(x, _lo, _hi), do: x
end
