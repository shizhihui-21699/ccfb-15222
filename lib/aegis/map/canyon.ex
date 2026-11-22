defmodule Aegis.Map.Canyon do
  @moduledoc """
  The sample world used by tests and the stress simulator.

  It is deliberately *not* a shooting gallery: it has long walls, narrow doors,
  wall corners, an open central arena, two portals and plenty of room behind
  walls where a cheater would love to shoot from.

  Geometry is in metres on a 2 m grid, 200 x 140 = 100 x 70 cells.
  """

  alias Aegis.Map

  def build do
    walls = [
      # outer structure (border is added automatically)
      # -- horizontal corridor walls with door gaps
      {20, 20, 60, 22},
      {70, 20, 110, 22},
      {130, 20, 170, 22},
      # -- long vertical wall splitting the north
      {100, 30, 102, 56},
      # -- central arena: four L-shaped corner blocks
      {70, 50, 74, 62},
      {74, 58, 90, 62},
      {126, 50, 130, 62},
      {110, 58, 126, 62},
      # -- south corridor
      {20, 100, 70, 102},
      {90, 100, 140, 102},
      {160, 100, 180, 102},
      # -- thick block with a single-cell door (corner-cut torture test)
      {40, 70, 44, 92},
      {44, 88, 62, 92},
      # -- isolated pillar (noclip target)
      {150, 70, 154, 74},
      # -- long thin wall (wall-flick test)
      {24, 50, 26, 84}
    ]

    portals = [
      %{
        id: :west_gate,
        trigger: {34.0, 34.0, 3.0},
        exit: {166.0, 34.0},
        cooldown_ms: 1_000,
        label: "west -> east gate"
      },
      %{
        id: :arena_drop,
        trigger: {100.0, 90.0, 3.0},
        exit: {108.0, 46.0},
        cooldown_ms: 1_500,
        label: "south -> arena"
      }
    ]

    Map.new(
      width: 200,
      height: 140,
      cell: 2.0,
      walls: walls,
      portals: portals,
      spawn: {100.0, 70.0},
      name: :canyon
    )
  end

  @doc "Convenience: build and install into `:persistent_term`."
  def install(key \\ :aegis_map), do: build() |> Map.install(key)
end
