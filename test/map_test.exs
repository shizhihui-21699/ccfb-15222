defmodule Aegis.MapTest do
  use ExUnit.Case, async: true

  alias Aegis.{Map, Path, Rules}

  setup do
    %{map: Map.Canyon.build()}
  end

  describe "geometry" do
    test "border is blocked", %{map: m} do
      refute Map.walkable?(m, {0.5, 70.0})
      refute Map.walkable?(m, {100.0, 139.5})
      assert Map.walkable?(m, {100.0, 70.0})
    end

    test "sweep is clear across open ground", %{map: m} do
      assert {:clear, len} = Map.sweep(m, {90.0, 70.0}, {110.0, 70.0})
      assert_in_delta len, 20.0, 0.01
    end

    test "sweep is blocked by the thin wall", %{map: m} do
      assert {:blocked, stop, d} = Map.sweep(m, {98.0, 40.0}, {104.0, 40.0})
      assert_in_delta stop |> elem(0), 100.0, 0.01
      assert d > 1.9
    end

    test "line of sight respects walls", %{map: m} do
      refute Map.line_of_sight?(m, {98.0, 40.0}, {106.0, 40.0})
      assert Map.line_of_sight?(m, {90.0, 70.0}, {110.0, 70.0})
    end

    test "nearest walkable finds ground next to a wall cell", %{map: m} do
      assert {:ok, p, d} = Map.nearest_walkable(m, {101.0, 40.0})
      assert Map.walkable?(m, p)
      assert d <= 4.0
    end
  end

  describe "portals" do
    test "trigger lookup", %{map: m} do
      assert {:ok, %{id: :west_gate}} = Map.portal_at(m, {34.0, 34.0})
      assert :none = Map.portal_at(m, {60.0, 30.0})
    end

    test "portal exits are walkable", %{map: m} do
      for p <- m.portals do
        assert Map.walkable?(m, p.exit), "#{p.id} exit must be walkable"
      end
    end
  end

  describe "path" do
    test "path around a wall is longer than the blocked chord", %{map: m} do
      {:ok, path} = Path.find(m, {98.0, 54.0}, {104.0, 58.0}, max_len: 30)

      len =
        path
        |> Enum.chunk_every(2, 1, :discard)
        |> Enum.map(fn [a, b] -> Map.dist(a, b) end)
        |> Enum.sum()

      assert len > Map.dist({98.0, 54.0}, {104.0, 58.0})
      assert len <= 30
    end

    test "opposite sides of a sealed wall are unreachable in a short detour", %{map: m} do
      refute Path.reachable?(m, {98.0, 40.0}, {106.0, 40.0}, 14.0)
    end

    test "same cell returns the destination", %{map: m} do
      assert {:ok, [{100.5, 70.5}]} = Path.find(m, {100.0, 70.0}, {100.5, 70.5})
    end
  end

  describe "rules" do
    test "enforced speed includes the tolerance headroom" do
      r = Rules.new()
      assert Rules.eff_speed(r) > r.max_speed
      assert Rules.budget_cap(r) == Rules.eff_speed(r) * r.burst_ms / 1000.0
    end
  end
end
