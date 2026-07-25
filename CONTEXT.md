# Playtime

Converts real-world time spent on worthwhile activities (tracked in the Timing app) plus manually-synced exercise time into a balance of earned play time, which is spent down by logging play sessions.

## Language

**Activity**:
A category of task that earns Play Minutes when time is logged against it. Maps 1:1 to a Timing Project by name/ID, and carries a Multiplier and an Activated At timestamp (only Timing entries on that Project from that moment onward count).
_Avoid_: Task, Chore, Project (Project is Timing's term for the underlying tracked entity; Activity is this app's wrapper around it with a multiplier attached)

**Multiplier**:
A decimal factor (may be below or above 1) attached to an Activity, applied to minutes spent to compute Play Minutes earned. Configured per Activity in the persistence backend, not hardcoded.

**Play Minutes**:
The unit of earned play time. Computed from Activities (minutes spent × Multiplier) or reported directly via a Manual Sync.

**Timing-Derived Earned Total**:
The live-computed sum of (entry duration × Multiplier) across every Timing entry on each Activity's mapped Project, counting only entries from that Activity's Activated At timestamp onward. Recomputed fresh each time the balance is shown — not a stored ledger, so editing an old Timing entry or changing an Activity's Multiplier changes this total retroactively.

**Manual Sync**:
An absolute total of Play Minutes, entered by hand from an external source (currently an iOS exercise app with its own timer). Each sync overwrites the previous Manual Sync value — it does not add to it.
_Avoid_: Sync delta, sync amount (it's a replace, not an increment)

**Playtime Used**:
A logged expenditure of Play Minutes (minutes + timestamp), decrementing the Play Balance. Recorded directly in this app, independent of Timing and the Manual Sync.
_Avoid_: Spend, consumption

**Play Balance**:
The current total available to spend: Timing-Derived Earned Total + Manual Sync − sum of Playtime Used. Accumulates indefinitely for now (a future cap is a known possibility, not yet designed).
_Avoid_: Balance (ambiguous outside this context), credit
