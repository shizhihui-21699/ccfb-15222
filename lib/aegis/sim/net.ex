defmodule Aegis.Sim.Net do
  @moduledoc """
  Deterministic link model: one-way latency, jitter, loss and reordering.

  Each simulated client generates an event at a **send** time (client clock)
  and the harness delivers it to the server at a **receive** time (server
  clock):

      recv = send + latency_ms + jitter

  Jitter is drawn per packet, so packets can arrive out of order — exactly what
  a real UDP link does and what makes naive "arrival interval" speed checks
  fail. Loss drops the packet entirely. Reordering is a consequence of jitter,
  not a separate mechanism.

  The model is seeded, so a failing run is reproducible from its seed.
  """

  defstruct [:latency_ms, :jitter_ms, :loss, :seed]

  @type t :: %__MODULE__{}

  def new(opts) do
    %__MODULE__{
      latency_ms: Keyword.get(opts, :latency_ms, 40),
      jitter_ms: Keyword.get(opts, :jitter_ms, 15),
      loss: Keyword.get(opts, :loss, 0.0),
      seed: Keyword.get(opts, :seed, 1)
    }
  end

  @doc """
  Returns `{:ok, recv_ms}` or `:lost`. `rng` is threaded so the caller owns it.
  """
  def send(net, send_ms, rng) do
    {jitter, rng} = uniform(rng, -net.jitter_ms, net.jitter_ms)
    {roll, rng} = uniform(rng, 0.0, 1.0)

    if roll < net.loss do
      {:lost, rng}
    else
      {:ok, send_ms + net.latency_ms + jitter, rng}
    end
  end

  # Uniform float in [lo, hi].
  def uniform(rng, lo, hi) do
    {u, rng} = :rand.uniform_s(rng)
    {lo + u * (hi - lo), rng}
  end

  def seeded(seed), do: :rand.seed_s(:exsss, {seed, seed * 7 + 1, seed * 13 + 3})
end
