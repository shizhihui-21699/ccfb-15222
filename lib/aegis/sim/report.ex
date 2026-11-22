defmodule Aegis.Sim.Report do
  @moduledoc "Human-readable rendering of `Aegis.Sim.Runner` results."

  def render(r) do
    s = r.setup
    t = r.throughput
    h = r.honest
    c = r.cheats

    """
    ==============================================================================
     AEGIS SERVER-AUTHORITATIVE VALIDATION — STRESS REPORT
    ==============================================================================
     actors            #{s.actors} (#{s.honest} honest, #{s.cheats} cheats)
     duration          #{s.seconds}s  @ #{s.dt_ms}ms tick
     packets processed #{s.packets}
     throughput        #{t.packets_per_sec} packets/s  (#{t.us_per_packet} µs/packet,
                       #{t.wall_seconds}s wall for #{s.seconds}s simulated)

    ------------------------------------------------------------------------------
     HONEST PLAYERS  (false positives must be zero-ish)
    ------------------------------------------------------------------------------
     moves                     #{h.moves}
     corrected (false positive)#{h.false_positive_moves}   (#{pct(h.false_positive_rate)})
     actors with any violation #{h.actors_with_any_violation}
     actors watched/banned     #{h.actors_watched} / #{h.actors_banned}
     violation breakdown       #{fmt_map(h.violations)}

    ------------------------------------------------------------------------------
     CHEATERS
    ------------------------------------------------------------------------------
     actors detected           #{c.actors_detected} / #{c.actors}
     move reports detected     #{c.detected_moves} / #{c.moves} (#{pct(c.move_detection_rate)})
     attacks rejected          #{c.attacks_rejected} / #{c.attacks}
     attacks accepted          #{c.attacks_stolen}  (hits the server confirmed;
                               for range/wall aimbots this should be ~0)

    #{profile_table(c.by_profile)}
    ==============================================================================
    """
  end

  defp profile_table(rows) do
    header =
      pad("profile", 16) <>
        pad("det", 8) <>
        pad("ban", 6) <>
        pad("move rej", 12) <>
        pad("atk rej", 12) <>
        pad("stolen", 8) <>
        "violations"

    lines =
      Enum.map(rows, fn p ->
        pad(to_string(p.profile), 16) <>
          pad("#{p.detected_actors}/#{p.actors}", 8) <>
          pad(to_string(p.banned), 6) <>
          pad("#{p.move_rejected}/#{p.moves}", 12) <>
          pad("#{p.attacks_rejected}/#{p.attacks}", 12) <>
          pad(to_string(p.attacks_stolen), 8) <>
          fmt_map(p.violations)
      end)

    Enum.join([header | lines], "\n")
  end

  defp fmt_map(m) when map_size(m) == 0, do: "-"

  defp fmt_map(m) do
    m
    |> Enum.sort_by(&elem(&1, 1), :desc)
    |> Enum.map_join(" ", fn {k, v} -> "#{k}=#{v}" end)
  end

  defp pct(f), do: "#{Float.round(f * 100, 3)}%"
  defp pad(s, n), do: String.pad_trailing(s, n)
end
