# Shared earliest-activation cutoff for batched Timing fetch

**Status**: accepted

Previously, the dashboard fetched Timing entries once (or twice: cumulative + today) per Activity, each call scoped to `["projects" => [that Activity's Project]]` and starting from *that Activity's own* Activated At. To cut this down to a single MCP call per dashboard load, we now issue one `list_time_entries` call covering every Activity's Project at once, with `start_date_min` set to the *earliest* Activated At across all of the User's Activities.

This means an Activity activated later than another can retroactively earn Play Minutes for Timing entries logged before it existed (as long as those entries fall after the earliest Activity's cutoff). We accepted this precision loss deliberately — it only matters for Users with multiple Activities activated on different dates, the effect is bounded (never earlier than the earliest Activity's own activation), and it buys a 1-call-per-load fetch instead of up to 2 calls per Activity.

## Considered options

- **Per-Activity client-side filtering after the shared fetch** — fetch the wide range once, then drop entries earlier than each Activity's own cutoff when bucketing by project. Preserves the original precision but was rejected for simplicity; revisit if the retroactive-earning behavior turns out to matter in practice.
- **Group Activities by activation day and issue one batched call per group** — preserves precision, costs more than 1 call when activation dates differ. Rejected as unnecessary complexity for the common case.
