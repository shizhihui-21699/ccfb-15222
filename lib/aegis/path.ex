defmodule Aegis.Path do
  @moduledoc """
  Bounded grid path search on the same raster the validator uses.

  Two uses:

    * server: when a reported segment's straight line is blocked, decide whether
      a *plausible* detour exists. An honest player cutting a corner needs a
      detour of roughly `direct + a couple of meters`; a noclip step through a
      wall needs a detour far longer than that (or none at all). The search is
      bounded by length and node count so it stays cheap on the hot path.
    * simulator: honest synthetic clients follow these paths so they never
      report wall-crossing movement by accident.

  Cheapest-first Dijkstra with an 8-neighbour grid. Diagonal steps are only
  allowed when both orthogonal cells are walkable, so paths never clip a corner.
  """

  @neighbors [
    {1, 0, :straight},
    {-1, 0, :straight},
    {0, 1, :straight},
    {0, -1, :straight},
    {1, 1, :diag},
    {1, -1, :diag},
    {-1, 1, :diag},
    {-1, -1, :diag}
  ]

  @doc """
  Find a path from `from` to `to`.

  Options:
    * `:max_len` - maximum path length in meters (default `:infinity`)
    * `:budget` - maximum nodes expanded (default 3000)

  Returns `{:ok, [point]}` (points to walk through, ending at `to`) or
  `{:error, :unreachable}`.
  """
  def find(map, from, to, opts \\ []) do
    max_len = Keyword.get(opts, :max_len, :infinity)
    budget = Keyword.get(opts, :budget, 3000)
    {sx, sy} = cell(map, from)
    {gx, gy} = cell(map, to)

    cond do
      not walkable_cell?(map, sx, sy) ->
        {:error, :unreachable}

      {sx, sy} == {gx, gy} ->
        {:ok, [to]}

      true ->
        diag = map.cell * 1.4142135623730951 * 1.0001
        heap = :gb_sets.singleton({0.0, sx, sy})
        dists = %{{sx, sy} => 0.0}
        prev = %{}
        search(map, heap, dists, prev, {gx, gy}, to, max_len, diag, budget)
    end
  end

  @doc "Shortest reachable path length up to `max_len`, or `:unreachable`."
  def reachable?(map, from, to, max_len) do
    case find(map, from, to, max_len: max_len, budget: 300) do
      {:ok, _path} -> true
      {:error, _} -> false
    end
  end

  defp search(_map, _heap, _dists, _prev, _goal, _to, _max_len, _diag, budget)
       when budget <= 0,
       do: {:error, :unreachable}

  defp search(map, heap, dists, prev, goal, to, max_len, diag, budget) do
    if :gb_sets.is_empty(heap) do
      {:error, :unreachable}
    else
      {{d, cx, cy}, heap} = :gb_sets.take_smallest(heap)

      if {cx, cy} == goal do
        {:ok, reconstruct(prev, goal, map, to) |> Enum.map(&cell_center(map, &1)) |> append(to)}
      else
        {heap, dists, prev} =
          Enum.reduce(@neighbors, {heap, dists, prev}, fn {dx, dy, kind}, {h, ds, pv} ->
            nx = cx + dx
            ny = cy + dy

            cond do
              not walkable_cell?(map, nx, ny) ->
                {h, ds, pv}

              kind == :diag and not walkable_cell?(map, cx + dx, cy) ->
                {h, ds, pv}

              kind == :diag and not walkable_cell?(map, cx, cy + dy) ->
                {h, ds, pv}

              true ->
                step = if kind == :straight, do: map.cell, else: diag
                nd = d + step

                cond do
                  max_len != :infinity and nd > max_len ->
                    {h, ds, pv}

                  Map.get(ds, {nx, ny}, :infinity) <= nd ->
                    {h, ds, pv}

                  true ->
                    {:gb_sets.add({nd, nx, ny}, h), Map.put(ds, {nx, ny}, nd),
                     Map.put(pv, {nx, ny}, {cx, cy})}
                end
            end
          end)

        search(map, heap, dists, prev, goal, to, max_len, diag, budget - 1)
      end
    end
  end

  defp reconstruct(prev, goal, _map, _to) do
    Stream.unfold(goal, fn
      nil -> nil
      cell -> {cell, Map.get(prev, cell)}
    end)
    |> Enum.reverse()
  end

  defp append(list, to) do
    case List.last(list) do
      nil -> [to]
      _ -> list ++ [to]
    end
  end

  defp cell_center(map, {cx, cy}),
    do: {cx * map.cell + map.cell / 2, cy * map.cell + map.cell / 2}

  defp cell(map, {x, y}), do: {trunc(x / map.cell), trunc(y / map.cell)}

  defp walkable_cell?(map, cx, cy) do
    cx >= 0 and cy >= 0 and cx < map.wc and cy < map.hc and
      :binary.at(map.cells, cy * map.wc + cx) == 0
  end
end
