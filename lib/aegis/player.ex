defmodule Aegis.Player do
  @moduledoc """
  Per-player authoritative state. Pure data structure; every validator call
  returns a new one.

  Two displacement windows are tracked:

    * `cwin` - accepted distance keyed on the **clamped client timeline**.
      This is the primary budget. Network jitter only distorts wall-clock
      intervals, never the client's own frame-to-frame deltas, so an honest
      player's window sum always matches `speed * time`.
    * `swin` - accepted distance keyed on **real server time**. Backstop
      against a forged clock: a client that runs its clock fast earns at most
      the per-packet clock allowance, and gross speed trips this window.

  `bucket` additionally lets a network stall (no packets for a while) be made
  up for, bounded by the window caps.
  """

  @history_ms 600
  @history_max 96

  defstruct [
    :id,
    :pos,
    # timeline anchoring
    :origin_server_ms,
    :origin_client_ts,
    :last_client_ts,
    :last_server_ms,
    :last_seq,
    # scoring
    :score,
    :score_t,
    :status,
    :joined_ms,
    # server-initiated displacement credit (meters), e.g. knockback / portal
    grant: 0.0,
    grant_expires: 0,
    # movement budgets
    bucket: 0.0,
    cwin: nil,
    swin: nil,
    # lag-compensation history: [{server_ms, pos}]
    history: [],
    portal_uses: %{},
    portal_grace: nil,
    # attack rate: {tokens, client_ms}, and server wall-clock arrivals
    rate: nil,
    last_attack_client_ts: nil,
    attack_window: [],
    stats: nil
  ]

  @type status :: :ok | :watch | :ban
  @type t :: %__MODULE__{}

  def new(id, pos, now) do
    %__MODULE__{
      id: id,
      pos: pos,
      origin_server_ms: now,
      last_server_ms: now,
      last_seq: -1,
      score: 0.0,
      score_t: now,
      status: :ok,
      joined_ms: now,
      bucket: 0.0,
      cwin: {:queue.new(), 0.0},
      swin: {:queue.new(), 0.0},
      history: [{now, pos}],
      rate: %{tokens: 1.0, t: nil},
      stats: new_stats()
    }
  end

  defp new_stats do
    %{
      moves: 0,
      moves_accepted: 0,
      moves_corrected: 0,
      attacks: 0,
      attacks_accepted: 0,
      attacks_rejected: 0,
      hits: 0,
      violations: %{},
      portals: 0,
      knockbacks: 0,
      max_score: 0.0,
      distance: 0.0
    }
  end

  def push_history(%__MODULE__{} = p, now, pos) do
    cutoff = now - @history_ms

    h =
      [{now, pos} | p.history]
      |> Enum.take_while(fn {t, _} -> t >= cutoff end)
      |> Enum.take(@history_max)

    %{p | history: h}
  end

  @doc "Positions the target occupied within the lag-compensation window."
  def recent_positions(%__MODULE__{history: h}, now, rewind_ms) do
    cutoff = now - rewind_ms
    Enum.take_while(h, fn {t, _} -> t >= cutoff end)
  end

  def note_violation(%__MODULE__{} = p, kind) do
    stats = p.stats
    violations = Map.update(stats.violations, kind, 1, &(&1 + 1))
    %{p | stats: %{stats | violations: violations}}
  end
end
