# RescueTime API: timestamp timezone semantics and query/filter capabilities

Research for issue #37 (part of map issue #36). Docs-only research — no live account
access performed here; see the companion Task ticket for empirical verification against
a real account.

Primary sources:
- https://www.rescuetime.com/rtx/developers (full "Analytic Data API" reference)
- https://help.rescuetime.com/article/463-api-overview (high-level overview, links back
  to the page above for the full reference)

## 1. Timezone of `restrict_begin`/`restrict_end` and returned row timestamps

**Not documented for the Analytic Data API.** The official reference
(`https://www.rescuetime.com/rtx/developers`) describes `restrict_begin`/`restrict_end` only as:

> Sets the start/end day for data batch, inclusive (always at time 00:00, start/end hour/minute
> not supported). Format: ISO 8601 "YYYY-MM-DD"

No timezone is named anywhere in the Analytic Data API section — not for `restrict_begin`/
`restrict_end`, and not for the `rows` timestamps returned by an `interval` (`perspective=interval`)
query. The docs never say "UTC" or "account timezone" in this section.

The only *explicit* timezone statements anywhere in the developer docs are for other endpoints,
not the Analytic Data API:
- **Daily Summary Feed**: "a full 24 hour period (defined by the user's selected time zone)"
  and "new summaries for the previous day are available at 12:01 am in the user's local time zone."
- **Alerts Feed** (`created_at`): "Time the alert was triggered (**in user's time zone**)"
- **Focus Session Feed** (`created_at`): "Time the session was started (**in user's time zone**)"

**Verdict: genuinely ambiguous / undocumented for the Analytic Data API specifically.** Every
other RescueTime endpoint that does state a timezone uses the account's configured local
timezone, not UTC, which makes "account-local timezone" the reasonable working assumption for
Analytic Data API day-boundaries and interval-row timestamps too (consistent with RescueTime's
UI, which reports in the user's local day). But this is an inference from adjacent-endpoint
behavior, not a documented fact for this endpoint. **This should be empirically verified** in
the live-account Task ticket (e.g. query `resolution_time=hour` across a UTC midnight/local
midnight boundary and inspect the returned interval timestamps) before ADR-0005's local-day
boundary logic relies on it.

## 2. Batching: can one request cover multiple activities/categories?

**Partially supported, but not via a list-valued `restrict_thing`.**

- `restrict_thing` (alias `taxon`) is documented as taking a single **name**: "The name of a
  specific overview, category, application or website." There is no documented syntax for
  passing multiple names (no comma-separated list, no repeated param, no array syntax) — it is
  a scalar field.
- `restrict_thing` is **optional**. Omitting it does not error; the docs' own worked example
  demonstrates this:

  > Request a list of time spent in each top level category, ranked by duration, for January 1, 2020:
  > `perspective=rank&restrict_kind=overview&restrict_begin=2020-01-01&restrict_end=2020-01-01&format=csv`

  This query has no `restrict_thing` at all and (per the `restrict_kind=overview` semantics —
  "sums statistics for all activities into their top level category") returns **all** top-level
  categories ranked by duration in one call. The same pattern applies with `restrict_kind=category`
  or `restrict_kind=activity`: omit `restrict_thing` to get every category/activity back in one
  response, then filter client-side.

**Verdict:** you cannot ask for an explicit *subset* of activities/categories (e.g. "activity A
and activity C but not B") in a single call — `restrict_thing` is one-name-or-omitted, not
list-valued. But you also don't need one-request-per-activity: omitting `restrict_thing` returns
everything for the chosen `restrict_kind` in a single call, which is the batching path for
ADR-0009 (avoid N+1). This should be treated as fetch-everything-then-filter, not
fetch-exactly-what-I-need.

## 3. `resolution_time=hour` support, and pagination/max-row behavior

**`hour` is a documented, first-class value** — it is not an undocumented/unsupported extra.
The full parameter table lists:

> `resolution_time` (short `rs`, alias `interval`): `['month' | 'week' | 'day' | 'hour' | 'minute']`.
> Default is "hour". ... "minute" returns data grouped into five-minute buckets, which is the
> most granular view available.

Note the docs claim the *default* value is "hour" (i.e. hourly resolution is not a secondary or
rarely-used option — it's the fallback if you don't specify a resolution at all).

**Pagination / max-row behavior: not documented at all.** The reference page has no section on
pagination parameters (no `page`, `offset`, `limit`/`cursor` fields anywhere in the query
parameter table), no stated maximum row count per response, and no mention of response
truncation for large date ranges. The JSON output section only describes the envelope shape
(`notes`, `row_headers`, `rows`) with no caveats about size limits. Likewise, no rate-limit
numbers are published in the developer docs or the API overview help article.

**Verdict: genuinely undocumented.** A multi-week `resolution_time=hour` query (a few hundred to
~1000 rows depending on range and whether `restrict_thing` is set) has no documented pagination
contract, no documented row cap, and no documented rate limit. This is a real gap: the
batched-fetch design (ADR-0009) should not assume unbounded single-call responses are safe
without empirically testing a several-week hourly pull against a live account (again, the
companion Task ticket) to observe actual response size/truncation behavior, and should consider
defensive chunking (e.g. by week) as a fallback if large hourly ranges turn out to be truncated
or slow in practice.

## Summary table

| Question | Answer | Confidence |
|---|---|---|
| Timezone of `restrict_begin`/`restrict_end` and row timestamps | Undocumented for this endpoint; other endpoints (Daily Summary, Alerts, Focus Session) explicitly use account-local time, so local-account-timezone is the reasonable inferred default — needs empirical confirmation | Low — inferred, not stated |
| Multiple activities/categories in one call | Yes, by omitting `restrict_thing` (returns everything for the chosen `restrict_kind`, filter client-side); no, there is no list-valued `restrict_thing` for an explicit subset | High — directly documented via worked example |
| `resolution_time=hour` supported | Yes, explicitly documented, and stated as the default value | High — directly documented |
| Pagination / max rows for multi-week hourly query | Not documented — no pagination params, no row cap, no rate limit published | High confidence that it's *undocumented* (i.e. a real gap, not something we missed) |

## Sources

- RescueTime API Documentation (Analytic Data API reference): https://www.rescuetime.com/rtx/developers
- API Overview: https://help.rescuetime.com/article/463-api-overview
