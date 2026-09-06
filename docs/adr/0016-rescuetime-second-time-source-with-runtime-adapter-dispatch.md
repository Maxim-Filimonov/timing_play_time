# RescueTime as a second TimeSource provider, with runtime per-User adapter dispatch

**Status**: accepted

## Context

`TimingPlayTime.Plugins.TimeSource` (ADR-0002) is a behaviour with one real
implementation — the Timing adapter — plus a `Stub` used in tests/dev. Which
module backs `@time_source` is fixed at **compile time**
(`Application.compile_env!(:timing_play_time, :time_source_adapter)`), read
into a module attribute in five places: `PlayBalance`, `EntryLedger`,
`DashboardLive`, `Mix.Tasks.Balance.Snapshot`,
`Mix.Tasks.Balance.BackfillConsumption`. Every User in a running app shares
the same adapter.

`Accounts.Integration` (ADR-0007) already stores a generic `provider ::
string` plus an opaque encrypted `credentials` map per User — the schema
was built for more than one provider from the start, only the dispatch
wasn't. Adding RescueTime Lite (free tier) as a second provider means two
things have to change together: a runtime, per-User way to pick which
adapter module answers a given call, and the adapter itself.

Charted in map #36 across three grilling rounds, a Research ticket (#37,
docs-only, `docs/research/rescuetime-api-timezone-and-batching.md`), a Task
ticket (#38, live account provisioning), and a Prototype ticket (#39,
`docs/research/rescuetime-entry-bucketing-prototype.md`, built against real
API responses). This ADR records what those settled.

## Decision

**1. Runtime adapter dispatch — `TimeSource.for/1`.**

```elixir
@spec for(TimingPlayTime.Accounts.Integration.t()) :: module()
def for(%Integration{provider: provider}), do: Map.fetch!(providers(), provider)
```

Lives on `TimingPlayTime.Plugins.TimeSource` itself (the behaviour module).
`providers/0` maps `"timing" => Timing, "rescuetime" => RescueTime`. In
`:test`, an application-env override
(`:timing_play_time, :time_source_adapter_override`, set only in
`config/test.exs`, defaulting to `Stub`) short-circuits before the provider
map is consulted — this keeps every existing test that builds an Integration
with `provider: "timing"` but expects Stub-like behavior (e.g.
`dashboard_live_test.exs`) working unchanged, without teaching `for/1` to
know it's running in a test.

The five existing call sites replace their `@time_source` module attribute
with: look up the User's Integration, resolve the module via `TimeSource.for/1`,
then pass that module's function captures explicitly wherever the call site
previously relied on the compile-time default (`PlayBalance`/`EntryLedger`'s
functions already accept an injectable fetcher as a trailing argument for
testing — this becomes their real production dispatch mechanism too, not
just a test seam).

`lib/timing_play_time/application.ex`'s boot-time
`Application.fetch_env!(:timing_play_time, :time_source_adapter)` and the
`config.exs` / `test.exs` `time_source_adapter:` key are removed — neither
adapter needs boot-time supervision (`Timing.start_link/1` doesn't exist as
an exported function; `RescueTime` needs none either, being a stateless
HTTP-based adapter), so nothing in `application.ex` depended on this beyond
the fetch itself.

**2. RescueTime adapter — API key, Activity-as-Source, single-call batching.**

New module `TimingPlayTime.Plugins.TimeSource.RescueTime`, implementing the
existing `TimeSource` behaviour unchanged (no new callbacks):

- **`connect/1`**: `credentials :: %{"api_key" => String.t()}`. Returns
  `{:ok, api_key}` — the bare key string *is* the opaque client handle (no
  persistent connection object; RescueTime's Data API is stateless REST).
  Mirrors Timing's `connect/1`: **no live verification call is made** at
  connect time either way — a bad key surfaces on the first real fetch, the
  same failure shape a bad Timing key already produces.
- **`list_sources/1`**: one `GET /anapi/data?restrict_kind=activity&perspective=rank&restrict_begin=<today-14d>&restrict_end=<today>` call (14 days: RescueTime Lite can't return anything older regardless, per the History Cap below, so there's no value in asking further back). Each returned row's `Activity` column becomes a `source.id` *and* `source.title` (RescueTime activities have no separate opaque id — the name is the id); its `Category` column becomes the sole entry in `ancestors` (`depth: 1`). A brand-new RescueTime account with no tracked history yet returns an empty source list — the picker's existing manual-id fallback (ADR-0014) handles this the same as any other empty/unavailable list, no new UI state needed.
- **`get_elapsed_minutes/2` and `list_entries/2`**: one
  `restrict_kind=activity&perspective=interval&resolution_time=hour` call
  covering the full requested range, **omitting `restrict_thing`** (batches
  every Activity in one call — `restrict_thing` is scalar/optional, not
  list-valued, confirmed #37) — then filtered client-side to just the given
  Activities' `time_source_identifier`s, mirroring
  `Timing.group_entries_by_activity/4`'s shape. Each returned row already
  carries both `Activity` and `Category`, so this one query shape serves
  both callbacks (Category-as-`ancestors` doesn't need a second call).
  `restrict_begin`/`restrict_end` accept **dates only, no time-of-day**
  (confirmed #37) — `:from`/`:to` are truncated to `Date` for the query
  boundary, and the adapter re-filters returned rows against the original
  `DateTime` bounds before building the result, so a sub-day window isn't
  silently widened to its containing days.
- **Pseudo-entry ids**: `list_entries/2` synthesizes
  `time_entry_id: sha256(activity_name <> "|" <> raw_bucket_timestamp) |>
  truncate(16 hex chars)` per row — verified stable across repeated
  identical fetches (#39). Matches the convention `EntryLedger.build_entries/2`
  already documents ("the real Timing adapter and the Stub both always
  supply one").
- **HTTP**: via `Req` (already a dependency). Test-injectable through a
  `plug:` override read from `Application.get_env(:timing_play_time,
  :rescuetime_req_plug)`, defaulting to none (real HTTP) — set only in
  tests, via `Req.Test`.

**3. Settings UX — mutually exclusive, warn-and-confirm switch.**

Two separate sections/buttons, "Connect Timing" / "Connect RescueTime" —
not a dropdown. Whichever provider is connected, the *other's* connect form
disappears; the connected one shows a "Disconnect" action instead of its
form. Disconnecting is not blocked, but if the User has any Activities, an
inline warning ("switching providers will stop these N Activities from
earning until you re-pick their Source") requires an explicit second
confirmation click before the disconnect proceeds; zero Activities skips
straight to disconnecting. Existing Activities are **left untouched** by a
switch — their `time_source_identifier`/`time_source_label` simply stop
matching anything from the new provider (both adapters' bucketing always
returns an empty-not-error bucket for an unmatched identifier, per
`Timing.group_entries_by_activity/4`'s existing "every Activity gets a
bucket" guarantee), so a switched Activity silently earns zero rather than
erroring, until the User re-picks its Source via the existing Edit Activity
flow. No bulk migration tooling.

**4. History cap and timezone — named residual risks, not resolved here.**

RescueTime Lite's 2-week server-side history cap is confirmed to exist (help
docs, third-party wrapper reports), but **what an out-of-cap query actually
returns (error vs. truncation vs. the same empty-`200` an in-range no-data
query returns) was not empirically distinguishable** — the test account
provisioned for #38/#39 turned out to have only 2 days of real history, too
young to tell "no data" apart from "capped." Likewise, returned bucket
timestamps carry no UTC-offset/zone marker, and no endpoint discloses the
account's configured timezone to check against — genuinely ambiguous after
two research/prototype passes. Both are accepted as **shipped-with-known-
unknowns**, not blockers: the adapter must treat an empty response as valid
regardless of cause (already true by construction — see above), and must
not hard-code a timezone assumption. The ready-for-agent spec names both
explicitly rather than silently assuming either away.

## Considered options

- **OAuth2 authentication for RescueTime.** Rejected: requires RescueTime
  approving a registered OAuth client first — an external dependency outside
  this effort's control — while a personal API key works today on the free
  Lite tier with no approval step, and fits ADR-0007's generic
  opaque-credential model just as well.
- **Simultaneous dual-provider Integrations** (both Timing and RescueTime
  connected at once). Rejected: nothing today needs more than one connected
  provider per User; `Accounts.Integration`'s `unique_constraint(:user_id)`
  already assumes at most one row, and a multi-row model would need its own
  migration and UX (which of two providers' data does an Activity read from)
  that nothing here requires.
- **Category-level as Source**, instead of Activity-level. Rejected: a
  User's actual interest ("time on `youtube.com`," not "time in `Video`")
  lives at the Activity level; RescueTime's fixed, largely uneditable
  Category taxonomy is a poor fit for a per-Activity Multiplier/Effect
  either way. Activity-as-Source, Category-as-`ancestors` mirrors how
  Timing's own Project-as-Source already works.
- **Blocking a provider switch outright** while Activities exist (forcing
  delete/archive first). Rejected as unnecessarily heavy-handed: the switch
  degrades gracefully (unmatched Activities just stop earning, they don't
  error or corrupt data), so a warn-and-confirm gate is enough to prevent
  surprise without forcing a destructive cleanup step first.
- **Blocking dispatch on a resolved 2-week-cap/timezone answer** before
  shipping RescueTime support at all. Rejected: both are genuinely
  unknowable without a longer-lived test account, which isn't available now;
  gating an entire provider on it would trade a known, contained risk
  (documented, non-crashing degradation) for an indefinite delay.

## Consequences

- `TimeSource` gains `for/1` (dispatch) alongside its existing three
  callbacks — no new behaviour callback, no schema change to `Integration`
  (ADR-0007's generic `provider`/`credentials` shape already supports this).
- Five call sites (`PlayBalance`, `EntryLedger`, `DashboardLive`,
  `Mix.Tasks.Balance.Snapshot`, `Mix.Tasks.Balance.BackfillConsumption`) move
  from a compile-time module attribute to a runtime per-User resolution;
  `application.ex` and both `config.exs`/`test.exs` lose the
  `time_source_adapter` key.
- `SettingsLive` gains a disconnect flow (new — none exists today for either
  provider) and a second connect form; `save_integration` is renamed/split
  per-provider.
- `CONTEXT.md`'s **Integration**, **Source**, and **Timing-Derived Earned
  Total** entries are updated to stop reading as Timing-exclusive.
- The 2-week-cap and timezone risks remain open for a future revisit once a
  longer-lived RescueTime Lite test account is available — tracked in the
  ready-for-agent spec's Further Notes, not re-litigated as a blocker here.
