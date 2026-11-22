defmodule Aegis.Rules do
  @moduledoc """
  Server-authoritative thresholds. Tune game numbers here, not in the
  validator.

  ## Why latency/packet loss cannot look like cheating

  Movement is gated on **accepted displacement**, measured against two clocks:

    * the **client timeline** - frame-to-frame deltas the client stamps. Loss
      and jitter stretch *arrival* intervals, but never the client's own
      deltas, so `sum(delta) == speed * elapsed` still holds for an honest
      player. A client cannot run this clock far ahead of real time: the
      timeline is clamped to `real_elapsed + max_clock_lead`.
    * the **server clock** - a backstop window. It only under-counts under
      loss, so it can never fabricate a false positive; it exists to catch a
      client whose (clamped) timeline is still allowed to creep ahead.

  A network stall earns budget at most `budget_cap` metres, because the
  per-packet bucket is capped there.

  ## Scoring

  Each violation adds a weight; the score decays with `half_life_ms`. `:watch`
  and `:ban` are score thresholds. Low-weight events (`:wall_graze`, 0.3)
  routinely decay to nothing between packets, so a flaky connection can never
  accumulate into a ban.
  """

  defstruct [
    # ---- movement ----
    max_speed: 6.6,
    # per-packet bucket capacity = max_speed * burst_ms; also the most a stall
    # can earn back at once
    burst_ms: 1_000,
    # a single-packet excess at or above this is a teleport, below it is speed
    teleport_excess: 2.5,
    # distance over which a blocked segment counts as a full wall (vs graze)
    wall_penetration: 1.5,
    # float / quantisation tolerance added to every budget check (metres)
    packet_slack: 0.1,
    # how far the first movement report may be from the server-assigned spawn
    # (absorbs join-time packet reordering; stops a join-packet teleport)
    join_tolerance: 4.0,
    # headroom above max_speed: honest clients rarely sit exactly on the cap.
    # Sustained speed ABOVE max_speed*(1+tolerance) is cheating.
    speed_tolerance: 0.10,

    # timeline clamp: the client timeline may lead real time by at most this
    max_clock_lead: 800,
    # per-step clock jump tolerance (stops "one giant frame" forging)
    clock_slack_ms: 300,
    clock_slack_ratio: 0.25,

    # ---- movement windows (server-relative) ----
    win_ms: 2_000,
    win_slack: 0.3,

    # ---- server-initiated displacement (knockback / portal) ----
    knockback_grant_ms: 1_500,

    # ---- combat ----
    weapon: %{
      range: 12.0,
      cooldown_ms: 150,
      # token bucket burst, absorbs out-of-order arrivals
      rate_burst: 2.0,
      # lag compensation: victim history searched within this window
      rewind_ms: 250,
      range_tolerance: 0.75,
      # how far a client-claimed firing origin may sit from an accepted
      # position (covers UDP reorder of the attacker's own move packet)
      max_origin_drift: 2.5
    },

    # ---- score weights ----
    weights: %{
      speed: 3.0,
      teleport: 20.0,
      wall: 12.0,
      wall_graze: 0.3,
      attack_range: 15.0,
      attack_rate: 8.0,
      event_hijack: 25.0,
      clock: 4.0
    },
    watch_score: 30.0,
    ban_score: 140.0,
    half_life_ms: 90_000
  ]

  @type t :: %__MODULE__{}

  def new(overrides \\ []) do
    Enum.reduce(overrides, %__MODULE__{}, fn {k, v}, acc -> Map.put(acc, k, v) end)
  end

  @doc "Speed actually enforced (max_speed with headroom applied)."
  def eff_speed(%__MODULE__{max_speed: s, speed_tolerance: t}), do: s * (1.0 + t)

  @doc "Per-packet displacement bucket capacity, in metres, at the enforced speed."
  def budget_cap(%__MODULE__{} = r), do: eff_speed(r) * r.burst_ms / 1000.0

  @doc "Client-timeline window capacity, in metres."
  def window_cap(%__MODULE__{} = r), do: eff_speed(r) * r.win_ms / 1000.0 + r.win_slack

  @doc "Server-clock window capacity (client cap plus one stall allowance)."
  def server_window_cap(%__MODULE__{} = r), do: window_cap(r) + budget_cap(r)

  @doc """
  Detour margin: when the straight segment is blocked, a route up to
  `direct + margin` counts as an honest corner cut rather than a wall breach.
  Corner cuts are about one cell longer; a noclip step is unreachable or far
  longer than this.
  """
  def wall_detour_margin(%__MODULE__{}, direct), do: max(4.0, direct * 0.6)
end
