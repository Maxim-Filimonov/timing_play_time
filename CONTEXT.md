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
A category of task that earns Play Minutes when time is logged against it. Maps 1:1 to a Timing Project by name/ID — scoped to the owning User's Integration, since each User now connects to their own Timing account — and carries a Multiplier and an Activated At timestamp (only Timing entries on that Project from the beginning of that timestamp's calendar day onward count).
_Avoid_: Task, Chore, Project (Project is Timing's term for the underlying tracked entity; Activity is this app's wrapper around it with a multiplier attached)

**Multiplier**:
A decimal factor (may be below or above 1) attached to an Activity, applied to minutes spent to compute Play Minutes earned. Configured per Activity in the persistence backend, not hardcoded.

**Play Minutes**:
The unit of earned play time. Computed from Activities (minutes spent × Multiplier) or reported directly via a Manual Sync. Also shown per-Activity scoped to just today (the local calendar day, per [ADR-0005](docs/adr/0005-local-timezone-for-day-boundaries.md)) alongside the raw Timing minutes it was computed from — a live day-scoped view of the same computation as the Timing-Derived Earned Total, not a separate stored figure.

**Timing-Derived Earned Total**:
The live-computed sum of (entry duration × Multiplier) across every Timing entry on each Activity's mapped Project, counting only entries from the beginning of the calendar day (UTC) containing that Activity's Activated At timestamp onward — so an Activity activated mid-day still earns for time already logged earlier that same day. Recomputed fresh each time the balance is shown — not a stored ledger, so editing an old Timing entry or changing an Activity's Multiplier changes this total retroactively.

**Manual Sync**:
An absolute total of Play Minutes, entered by hand from an external source (currently an iOS exercise app with its own timer). Each sync overwrites the previous Manual Sync value — it does not add to it. Displayed to the user as "Exercise Minutes" in the UI — "sync" is developer jargon; the underlying replace-not-add semantics are unchanged, only the label differs.
_Avoid_: Sync delta, sync amount (it's a replace, not an increment)

**Playtime Used**:
A logged expenditure of Play Minutes (minutes + timestamp), decrementing the Play Balance. Recorded directly in this app, independent of Timing and the Manual Sync.
_Avoid_: Spend, consumption

**Play Balance**:
The current total available to spend: Timing-Derived Earned Total + Manual Sync − sum of Playtime Used. Accumulates indefinitely for now (a future cap is a known possibility, not yet designed). Shown only behind a debug-only reveal on the dashboard (triple-tap the joystick icon) — the primary hero figure is Playtime, below. Always equal to Playtime's Today's PT + Reserve — a pure decomposition of the same total, nothing added or dropped.
_Avoid_: Balance (ambiguous outside this context), credit

**Playtime**:
The dashboard's primary hero figure: Today's PT + Reserve. Unclamped — can go negative if usage has outpaced earnings. Distinct from Play Balance (above), which is the same total computed a different way and normally hidden.

**Today's PT**:
The "today" component of Playtime: today's Timing-Derived Earned Total (local calendar day, per [ADR-0005](docs/adr/0005-local-timezone-for-day-boundaries.md)) minus today's Playtime Used, plus all-time Exercise Minutes. Exercise Minutes is folded in here rather than into Reserve because Manual Sync has no day boundary of its own to split by.

**Reserve**:
Play Minutes earned but not yet spent from days *before* today: prior-days' Timing-Derived Earned Total minus prior-days' Playtime Used. Unclamped (can go negative). Excludes Exercise Minutes entirely (see Today's PT). Shown as its own dashboard widget, separate from Today's PT, so today's activity and carried-over history stay visually distinguishable even though they combine into a single spendable Playtime number.
