defmodule TimingPlayTime.PlayBalance.Today do
  @moduledoc """
  The dashboard's ledger-based "today" figures (ADR-0010) — the return
  shape of `TimingPlayTime.PlayBalance.compute_today/4`.

  ## Fields

    * `:earned_today` / `:drained_today` / `:used_today` - today's raw
      (non-ledger) totals: the gross positive magnitude earned by positive
      Activities, the gross positive magnitude of today's Draining
      Activities (ADR-0013), and how much was spent today — each
      independent of what a spend was actually matched against.
    * `:week_earned` / `:week_drained` / `:week_used` - the Entry Expiry
      Window's raw totals: every in-window positive entry's original
      `play_minutes`, every in-window drain entry's magnitude, and every
      recent usage's `minutes`, all summed with no ledger involved.
      `:week_earned` stays gross — a week of 300 earned against 280
      drained reads as exactly that, not as "20m earned".
    * `:pushscroll_balance` - the current Manual Sync value.
    * `:today_net` - today's earned Play Minutes, net of the Entry
      Consumption Ledger's draw-down. Never negative.
    * `:reserve` - prior-days' User Displayed Total plus Pushscroll
      Balance, minus any unmatched overflow (`:deficit`, see
      `TimingPlayTime.PlayBalance.compute_today/4`). Can go negative — as
      of ADR-0012, more readily than before, since a spend can no longer
      fall back on Backlog once today's and Reserve's in-window entries
      run dry.
    * `:playtime` - `:today_net + :reserve`, the dashboard's hero figure.
      Unclamped.

      **`playtime == week_earned - week_drained - week_used +
      pushscroll_balance`, for almost every spend** logged after
      [ADR-0012](../../../docs/adr/0012-persisted-entry-consumption-ledger-with-window-bounded-spending.md),
      since a spend can no longer draw on Backlog, there's nothing outside
      this week's own earned/used to reconcile (see
      `TimingPlayTime.PlayBalance.compute_today/4` for the full
      derivation). One known gap: an entry can age out of the window (from
      a *later* read) after funding a usage that's still in-window at that
      read — an entry is always at least as old as the usage it funded.
      ADR-0010's `backlog_drawn` used to paper over exactly this; ADR-0012
      dropped it deliberately (KISS) rather than replace it, so this is a
      sanity check, not a hard invariant. This ADR-0012 also removed the old
      `:backlog_drawn`,
      `:backlog_remaining`, and `:receipts` — the last because a spend's
      receipt is now returned directly by `PlayBalance.log_spend/6` at the
      moment it's logged, rather than reconstructed here by replaying
      usage history.
  """

  @enforce_keys [
    :earned_today,
    :drained_today,
    :used_today,
    :week_earned,
    :week_drained,
    :week_used,
    :pushscroll_balance,
    :today_net,
    :reserve,
    :playtime
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          earned_today: float(),
          drained_today: float(),
          used_today: float(),
          week_earned: float(),
          week_drained: float(),
          week_used: float(),
          pushscroll_balance: float(),
          today_net: float(),
          reserve: float(),
          playtime: float()
        }
end
