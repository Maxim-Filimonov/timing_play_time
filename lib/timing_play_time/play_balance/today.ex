defmodule TimingPlayTime.PlayBalance.Today do
  @moduledoc """
  The dashboard's ledger-based "today" figures (ADR-0010) — the return
  shape of `TimingPlayTime.PlayBalance.compute_today/4`.

  ## Fields

    * `:earned_today` / `:used_today` - today's raw (non-ledger) totals:
      how much was earned/spent today, independent of what a spend was
      actually matched against.
    * `:week_earned` / `:week_used` - the Entry Expiry Window's raw
      totals: every in-window entry's original `play_minutes`, and every
      recent usage's `minutes`, both summed with no ledger involved.
    * `:backlog_drawn` - the one figure here that *does* need the Entry
      Consumption Ledger: the total minutes this week's usages drew from
      entries *outside* the window, once in-window entries ran out. Not
      counted in `:week_earned`, so spending against it wouldn't
      otherwise show up anywhere in this week's math.
    * `:pushscroll_balance` - the current Manual Sync value.
    * `:today_net` - today's earned Play Minutes, net of the Entry
      Consumption Ledger's draw-down. Never negative.
    * `:reserve` - prior-days' User Displayed Total plus Pushscroll
      Balance, minus any unmatched overflow. Can go negative.
    * `:playtime` - `:today_net + :reserve`, the dashboard's hero figure.
      Unclamped.

      **`playtime == week_earned - week_used + backlog_drawn +
      pushscroll_balance`, exactly, always** — the ledger's `:deficit` is
      by construction the part of `week_used` that didn't come out of any
      entry's `remaining`, in-window or not (`consumed_in_window +
      backlog_drawn + deficit == week_used`), so it cancels out of this
      identity algebraically even though it's very much present inside
      `today_net`/`reserve`'s own math (see
      `TimingPlayTime.PlayBalance.compute_today/4` for the full
      derivation). This is what makes `week_earned`/`week_used`/
      `backlog_drawn` worth showing next to `playtime` — checkable by eye,
      unlike `today_net + reserve`.

    * `:receipts` - one Spend Receipt per usage (see
      `TimingPlayTime.EntryLedger.replay/4`).
  """

  @enforce_keys [
    :earned_today,
    :used_today,
    :week_earned,
    :week_used,
    :backlog_drawn,
    :pushscroll_balance,
    :today_net,
    :reserve,
    :playtime,
    :receipts
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          earned_today: float(),
          used_today: float(),
          week_earned: float(),
          week_used: float(),
          backlog_drawn: float(),
          pushscroll_balance: float(),
          today_net: float(),
          reserve: float(),
          playtime: float(),
          receipts: [TimingPlayTime.EntryLedger.receipt()]
        }
end
