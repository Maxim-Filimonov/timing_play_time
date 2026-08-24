# Surface Backlog Remaining alongside Backlog Drawn

**Status**: superseded by [ADR-0012](0012-persisted-entry-consumption-ledger-with-window-bounded-spending.md)

A User logged a large Playtime Used spend and expected Reserve to go negative, since it visibly exceeded This Week's Earned and the displayed Reserve figure. Instead Reserve held steady. This was correct — ADR-0010's `EntryLedger.replay/4` draws on the User's full, unbounded entry history as overflow before ever recording a `deficit` — but it was surprising, because nothing on the dashboard showed that a large, older-than-the-window balance existed to absorb the spend. `backlog_drawn` (ADR-0010's third amendment) shows what *has* been drawn from that backlog this week, but nothing showed what's still *there* to draw on.

We added `backlog_remaining` to `PlayBalance.compute_today/4`'s return (`TimingPlayTime.PlayBalance.Today`): the sum of `remaining` across every ledger entry outside the Entry Expiry Window, computed from the same `out_of_window` list `backlog_drawn` already derives from — no new fetch, no new ledger pass. It's the flip side of `backlog_drawn`: `backlog_drawn` is what this week's spending already took from the backlog; `backlog_remaining` is what's left there for the *next* spend to draw on.

Displayed on the dashboard directly under "From Backlog" in the This Week card, always shown (including `0.0`), matching the "predictable, not intermittent" principle ADR-0010 established for Spend Receipts and `backlog_drawn`.

## Considered options

- **Unbounded vs. bounded by Activated At** — considered bounding `backlog_remaining` to each Activity's Activated At, so it wouldn't include Timing history predating the User's opt-in to this app's economy. Rejected: the ledger's actual draw-down is unbounded and ignores Activated At (ADR-0010's amendment), so a bounded number here would *understate* what a real overflow spend can reach — recreating the exact "Reserve held steady and I don't know why" surprise this feature exists to fix.
- **Including Pushscroll Balance** — rejected. Pushscroll Balance has no per-entry `start_date`, so it can't meaningfully be "inside" or "outside" the window; it's already visible in its own card, and folding it in here would double-count it against `backlog_drawn`, which also excludes it.
- **New dashboard card vs. sub-line in an existing one** — considered a 5th card in the hero grid (`Today's` / `This Week` / `Reserve` / `Pushscroll Balance`). Rejected in favor of a sub-line under "From Backlog" in the existing This Week card: it's the direct complement of a figure already there, and avoids reworking the grid layout for one new number.
- **Amending ADR-0010 instead of a new ADR** — considered, since this is directly downstream of ADR-0010's "entries are unbounded, only usages are windowed" decision (already amended three times). Decided on a new ADR instead, at the User's explicit preference.

## Consequences

- `TimingPlayTime.PlayBalance.Today` gains a tenth field, `:backlog_remaining` — every construction site (`compute_today/4`, `DashboardLive.@empty_today`, `Mix.Tasks.Balance.Snapshot`) needed updating; `@enforce_keys` caught all of them at compile time.
- `backlog_remaining` is descriptive only — it does not participate in the `playtime == week_earned - week_used + backlog_drawn + pushscroll_balance` reconciliation identity (ADR-0010), since it's a snapshot of what's left, not a component of what moved this week.
- A User can now see, at a glance, roughly how much further a spend could go before Reserve would actually turn negative.
