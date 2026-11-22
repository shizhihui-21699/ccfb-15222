defmodule Aegis.Sim.Route do
  @moduledoc """
  Generates a long, plausible moving route for a synthetic player:

  1. pick a random walkable start and goal;
  2. find a grid path around the geometry with `Aegis.Path`;
  3. resample it at the player's speed into a continuous track.

  Every synthetic honest player follows a legal route at exactly `max_speed`
  (optionally scaled by `speed_factor`), so any correction they receive is a
  false positive of the validator, not a simulator artefact.

  The generated points are *legal against the map*: they lie on a path found by
  the same `Path` module the validator uses for wall plausibility, so the
  straight chords between consecutive points never cross a wall.

  Route segments may include a crossing of a portal trigger so the simulator
  exercises that path too; portal teleports are applied by the server, so the
  client's own reported track simply continues from the exit.
  """

  alias Aegis.{Map, Path}

  @type point :: {float(), float()}

  @doc """
  Build a route between two random walkable points.

  Returns `%{points: [point], length: float, duration_ms: float}` where points
  are spaced by `speed_mps * dt_ms/1000`.
  """
  def random(map, speed_mps, dt_ms, rng, opts \\ []) do
    tries = Keyword.get(opts, :tries, 8)
    do_random(map, speed_mps, dt_ms, rng, tries)
  end

  defp do_random(map, speed_mps, dt_ms, rng, tries) do
    {start, rng} = random_point(map, rng)
    {goal, rng} = random_point(map, rng)

    case Path.find(map, start, goal, max_len: 400, budget: 20_000) do
      {:ok, path} when tries > 0 ->
        spacing = max(speed_mps * dt_ms / 1000.0, 0.05)
        points = resample([start | path], spacing)

        # Plain walking routes deliberately avoid portal triggers: a portal
        # teleport is a separate, server-driven action covered by dedicated
        # tests, and mixing it into an "honest walking" route would just be
        # measuring the simulator's own bookkeeping.
        if crosses_portal?(map, points) do
          do_random(map, speed_mps, dt_ms, rng, tries - 1)
        else
          {%{points: points, dt_ms: dt_ms, speed: speed_mps}, rng}
        end

      _ when tries > 1 ->
        do_random(map, speed_mps, dt_ms, rng, tries - 1)

      {:ok, path} ->
        spacing = max(speed_mps * dt_ms / 1000.0, 0.05)
        points = resample([start | path], spacing)
        {%{points: points, dt_ms: dt_ms, speed: speed_mps}, rng}
    end
  end

  defp crosses_portal?(map, points) do
    Enum.any?(points, fn pt -> Aegis.Map.portal_at(map, pt) != :none end)
  end

  def random_point(map, rng) do
    {x, rng} = uniform(rng, map.cell, map.width - map.cell)
    {y, rng} = uniform(rng, map.cell, map.height - map.cell)

    if Map.walkable?(map, {x, y}) do
      {{x, y}, rng}
    else
      random_point(map, rng)
    end
  end

  def resample([_single], _spacing), do: []

  def resample(points, spacing) do
    points
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.flat_map(fn [a, b] ->
      n = max(1, ceil(Map.dist(a, b) / spacing))
      for i <- 1..n, do: Map.point_at(a, b, i / n)
    end)
  end

  defp uniform(rng, lo, hi) do
    {u, rng} = :rand.uniform_s(rng)
    {lo + u * (hi - lo), rng}
  end
end
