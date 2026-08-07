# Playtime

Converts real-world time spent on worthwhile activities (tracked in the Timing app) plus manually-synced exercise time into a balance of earned play time, which is spent down by logging play sessions.

## Language

**User**:
The tenant boundary. Owns Activities, the Play Balance, an Integration, and a timezone. Identity is an anonymous, long-lived session cookie (see [ADR-0006](docs/adr/0006-multi-tenant-anonymous-cookie-accounts.md)) — there is no login, password, or email attached to a User; losing the cookie means losing access to that User's data.
_Avoid_: Account, tenant (User is this app's term; "account" implies a login credential that doesn't exist here)

**Integration**:
A User's connection to one external time-tracking provider at a time (currently only Timing), holding provider-specific encrypted credentials (see [ADR-0007](docs/adr/0007-generic-per-user-integration-credentials.md)). Replaces what was previously a single global Timing API key shared by the whole app.
_Avoid_: Connection, provider config

**Activity**:
A category of task that earns Play Minutes when time is logged against it. Maps 1:1 to a Timing Project by name/ID — scoped to the owning User's Integration, since each User now connects to their own Timing account — and carries a Multiplier and an Activated At timestamp. Activated At still bounds which entries count toward the debug-only Timing-Derived Earned Total (below), but is purely descriptive — not load-bearing — for the user-facing User Displayed Total, which uses a fixed rolling window instead (see User Displayed Total).
_Avoid_: Task, Chore, Project (Project is Timing's term for the underlying tracked entity; Activity is this app's wrapper around it with a multiplier attached)

**Multiplier**:
A decimal factor (may be below or above 1) attached to an Activity, applied to minutes spent to compute Play Minutes earned. Configured per Activity in the persistence backend, not hardcoded.

**Play Minutes**:
The unit of earned play time. Computed from Activities (minutes spent × Multiplier) or reported directly via a Manual Sync. Also shown per-Activity scoped to just today (the local calendar day, per [ADR-0005](docs/adr/0005-local-timezone-for-day-boundaries.md)) alongside the raw Timing minutes it was computed from — a live day-scoped view of the same computation as User Displayed Total, not a separate stored figure. (Today is always within the Entry Expiry Window, so this view is unaffected by expiry in practice.)

**Timing-Derived Earned Total**:
The live-computed, all-time sum of (entry duration × Multiplier) across every Timing entry on each Activity's mapped Project, counting only entries from the beginning of the calendar day (UTC) containing the *earliest* Activated At timestamp across the User's Activities onward — one shared cutoff applied to every one of that User's Activities, not a separate cutoff per Activity. This means an Activity activated after another of the User's Activities can retroactively earn for Timing entries logged before it existed, as long as they fall after the earliest Activity's cutoff (see [ADR-0008](docs/adr/0008-shared-earliest-activation-cutoff-for-batched-timing-fetch.md)) — a deliberate precision-for-efficiency trade-off, made so all of a User's Activities can be fetched from Timing in a single batched call instead of one call per Activity. Recomputed fresh each time it's shown — not a stored ledger, so editing an old Timing entry or changing an Activity's Multiplier changes this total retroactively. **Debug-only**: as of the Entry Expiry Window decision, this unbounded figure powers only the debug-only Play Balance reveal (triple-tap the joystick icon); every user-facing figure (Playtime, Today's PT, Reserve) uses User Displayed Total instead.

**Entry Expiry Window**:
The rule that a Timing entry stops counting toward User Displayed Total once more than 7 days have passed since the entry's own `start_date` — an exact rolling timestamp cutoff (`now − 7 days`), re-evaluated on every read, not aligned to local calendar days. Applies only to Timing entries; Pushscroll Balance (a Manual Sync value) is exempt, since it has no per-entry timestamp to decay against. Deliberately makes Reserve shrink over time even with no new Playtime Used logged against it — the intended effect, to keep a standing Reserve from removing the incentive to keep doing Activities.

**Entry Consumption Ledger**:
The per-entry FIFO record of how much of each Timing entry's earned minutes remain unspent. A logged Playtime Used spend draws down entries in two passes, preserving Today's PT's existing "resets fresh every local day, no exceptions" rule: first, consume today's own entries (today's local calendar day, per [ADR-0005](docs/adr/0005-local-timezone-for-day-boundaries.md)); only if the spend exceeds what's available there does it spill into Reserve's entries, oldest-`start_date`-first among those. Each entry's `remaining` balance drops as it's consumed. An entry's `remaining` (not its original earned amount) is what the Entry Expiry Window acts on — once `remaining` reaches 0 (fully spent) an entry's later expiry has no effect, since there's nothing left on it to lose. Computed live on every read, walking the full entry history, not persisted as a running mutation — consistent with the rest of this app's "recomputed fresh, not stored" pattern.

**Spend Receipt**:
A per-Activity breakdown of which Activities' entries funded a given Playtime Used spend, derived from the Entry Consumption Ledger's draw-down at the moment that spend is displayed. Always shown alongside the logged spend — even when a single Activity funded 100% of it — rather than only appearing for multi-Activity spends, so the UI element is predictable rather than one that intermittently appears.

**User Displayed Total**:
The Timing-derived earned total actually shown to the user, via Playtime and Reserve: the sum of each Timing entry's `remaining` balance (Entry Consumption Ledger, above), for every entry still within the Entry Expiry Window (the last 7 days from `now`), across every one of the User's Activities — one shared fixed cutoff, not scoped per Activity, and not bounded by any Activity's Activated At. Recomputed fresh each time it's shown, the same as Timing-Derived Earned Total, but bounded to a rolling week and ledger-aware rather than a raw all-time sum. Because expiry only removes *unspent remaining* balance, this can never go negative from expiry alone — it's exactly the earned-but-not-yet-spent minutes still inside the window, no more, no less.

**Manual Sync**:
An absolute total of Play Minutes, entered by hand from an external source (currently Pushscroll, an iOS app with its own earn/spend economy — no API, so syncing is manual). Each sync overwrites the previous Manual Sync value — it does not add to it, because the number entered is already Pushscroll's own net balance, not a delta. Displayed to the user as "Pushscroll Balance" in the UI — "sync" is developer jargon, and "Exercise Minutes" undersold that the figure is bidirectional (Pushscroll's balance rises when the User exercises and *falls* when they spend it on Pushscroll-tracked apps); only the label differs, the underlying replace-not-add semantics are unchanged. A drop in Pushscroll Balance lowers Reserve (see below) by design — spending time on a Pushscroll-tracked app costs Play Minutes the same way logging Playtime Used does, just through a different app's accounting.
_Avoid_: Sync delta, sync amount (it's a replace, not an increment); Exercise Minutes (implies one-directional, exercise-only growth)

**Playtime Used**:
A logged expenditure of Play Minutes (minutes + timestamp), decrementing the Play Balance. Recorded directly in this app, independent of Timing and the Manual Sync.
_Avoid_: Spend, consumption

**Play Balance**:
The current total available to spend: Timing-Derived Earned Total + Manual Sync − sum of Playtime Used. Accumulates indefinitely for now (a future cap is a known possibility, not yet designed). Shown only behind a debug-only reveal on the dashboard (triple-tap the joystick icon) — the primary hero figure is Playtime, below. Always equal to Playtime's Today's PT + Reserve — a pure decomposition of the same total, nothing added or dropped.
_Avoid_: Balance (ambiguous outside this context), credit

**Playtime**:
The dashboard's primary hero figure: Today's PT + Reserve. Unclamped — can go negative if usage has outpaced earnings. Distinct from Play Balance (above), which is the same total computed a different way and normally hidden. Also exactly equal to This Week's Earned minus This Week's Used plus Pushscroll Balance (see This Week) — a second, independent decomposition of the same number, shown alongside the hero figure specifically because it needs no explanation of flooring or causality to verify by eye, unlike Today's PT + Reserve.

**This Week**:
The Entry Expiry Window's raw (non-ledger) totals: every entry within the last 7 days' original earned minutes summed ("Earned"), and every Playtime Used record within the same window summed ("Used"), each with no consumption/FIFO logic applied. Shown per-Activity (gross earned only, since Playtime Used draws from one global pool, not a per-Activity one — see Playtime Used) and as a whole-User total alongside Today's. `This Week's Earned − This Week's Used + Pushscroll Balance == Playtime`, exactly, always — the Entry Consumption Ledger's `deficit` cancels out of this identity algebraically even though it's very much present inside Today's PT/Reserve's own math, which is what makes this pairing checkable by eye where Today's PT/Reserve isn't.

**Today's PT**:
The "today" component of Playtime: the sum of today's entries' `remaining` balance (Entry Consumption Ledger, local calendar day per [ADR-0005](docs/adr/0005-local-timezone-for-day-boundaries.md)) after the day's own Playtime Used has drawn against it. Resets to just today's activity every local calendar day, with no exceptions — Pushscroll Balance lives in Reserve instead (see below), since it has no day boundary of its own to reset by. Unlike Playtime, this is never negative: a spend consumes today's own entries first and only *overflows* into Reserve once they're exhausted (see Reserve), so there's nothing left on today's entries to go negative.

**Reserve**:
Play Minutes earned but not yet spent, that aren't scoped to today: prior-days' User Displayed Total (itself already net of spending, via the Entry Consumption Ledger) *plus* the current Pushscroll Balance (a Manual Sync value, above), *minus* any unmatched overflow — spend, from any day, that exceeded every entry available (today's and Reserve's) at the moment it was logged, once the ledger's draw-down has nothing left to charge it against. Pushscroll Balance is grouped here rather than with Today's PT because both share the same shape — carried-over credit with no day boundary of its own — unlike Today's PT, which resets every midnight. Can still go negative overall (if Pushscroll Balance itself is negative, or a day's overspend overflows past everything available — see Today's PT), but never negative *purely from expiry*, since expiry only removes minutes already known to be unspent. Shown as its own dashboard widget, separate from Today's PT, so today's activity and carried-over history stay visually distinguishable even though they combine into a single spendable Playtime number.
