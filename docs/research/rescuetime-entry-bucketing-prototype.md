# Prototype: RescueTime entry bucketing and batched-fetch strategy

Answers issue #39 (part of map #36). Built against a real RescueTime Lite
account via `scripts/prototype_rescuetime_entries.exs` (throwaway, this branch
only — run with `mix run scripts/prototype_rescuetime_entries.exs`, needs
`RESCUETIME_API_KEY` in a local `.env`).

## 1. Bucket resolution

**`resolution_time=hour` confirmed as the right starting point** — real
`restrict_kind=activity&perspective=interval&resolution_time=hour` rows look
like:

```
["2026-09-05T20:00:00", 1152, 1, "youtube.com", "Video", -2]
```

`row_headers`: `["Date", "Time Spent (seconds)", "Number of People", "Activity", "Category", "Productivity"]`.

Unplanned bonus: **Activity and Category arrive in the same row.** The map's
Notes assumed a separate category-level query might be needed to build each
Source's `ancestors`; in practice one `restrict_kind=activity` query returns
both, so `list_entries/2` and the Category-as-ancestor lookup for
`list_sources/1` can both be satisfied from the same query shape.

## 2. Pseudo-entry id synthesis

`sha256(activity_name <> "|" <> raw_bucket_timestamp)`, truncated to 16 hex
chars, e.g. `"youtube.com" <> "|" <> "2026-09-05T20:00:00"` →
`87452f9bd9a1ce2c`. **Verified stable**: re-running the identical query
returned the same ids for the same (activity, bucket) pairs. Good enough for
ledger keying — collisions would require the same activity name to produce
the same bucket timestamp twice, which the API's own bucketing already
prevents (one row per activity per bucket).

## 3. Batching across Activities

Confirmed: omitting `restrict_thing` on `restrict_kind=activity` returns
**every** activity for the window in one call — a single day's hourly query
returned 20+ distinct activity names in one response. The batching strategy
is: one call per (User, fetch window), then filter the returned rows down to
just the `time_source_identifier`s the caller asked about — never one call
per Activity. Matches ADR-0009 and [[feedback_n_plus_1_adapter_design]].

## 4. `:from` / unbounded fetch vs. the 2-week Lite cap — **not resolved, test account too new**

This is the one sub-question the prototype could not settle. The test
account provisioned in issue #38 only has **two days of real data**
(2026-09-05 and 2026-09-06 — confirmed via a `restrict_kind=overview,
resolution_time=day` query over 2026-08-01..2026-09-06, which returned rows
for only those two dates). Every out-of-range probe — both 45-60 days back
and a 12-13 day "should still be inside the cap" control — came back
`{"rows": []}`, but that's indistinguishable from "no data exists" vs. "the
API silently clamps/empties requests past the cap." **The account is too
young to tell these apart.**

What we do know from this: an out-of-range or no-data request returns
`{"rows": []}` with **HTTP 200**, not an error — so `list_entries/2` at
minimum needs to treat an empty row list as a valid, non-error response
either way. Whether the 2-week cap itself produces something different (an
error, a truncated range, or the same empty-with-200) is still open —
revisit once this account has 2+ weeks of continuous history, or test
against an older Lite account if one becomes available.

## Timezone — still ambiguous, carried forward from issue #37

Returned timestamps (`"2026-09-05T20:00:00"`) carry **no UTC offset or zone
marker**. I could not find an endpoint on this key that discloses the
account's configured timezone to cross-check against, so I can't
conclusively determine whether these are UTC or account-local. This
prototype does not resolve the risk flagged in the closed Research ticket
(#37) — it's carried forward as-is. Recommendation for the eventual adapter:
don't hard-code an assumption; either have the user confirm their RescueTime
account's timezone setting matches what Playtime expects, or do a live
calibration check at connect-time (e.g. compare a known recent bucket
against wall-clock) rather than guessing.

## Verdict

Q1-3 are settled and ready for the eventual spec. Q4 and the timezone
question remain genuinely open — not for lack of trying, but because this
account can't produce the evidence yet. Both should be named explicitly as
residual risks in the eventual `ready-for-agent` spec, not silently assumed
away.
