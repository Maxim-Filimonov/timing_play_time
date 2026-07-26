# Required TZ env var for local calendar-day boundaries

**Status**: partially superseded by [ADR-0006](0006-multi-tenant-anonymous-cookie-accounts.md) — the "single-user, no per-user timezone" premise and the required-env-var delivery mechanism are superseded; the local-timezone day-boundary math and `tzdata` dependency below are unchanged.

Every day-boundary calculation in the domain today is UTC (e.g. Timing-Derived Earned Total's "beginning of the calendar day containing Activated At"). Adding a per-Activity "today" breakdown surfaced that UTC-day boundaries are wrong for a user far from UTC — the day rolls over at noon or 1pm local time, so "today" numbers wouldn't match what the user means by today. We introduce a required `TZ` environment variable holding an IANA timezone name (e.g. `Pacific/Auckland`), used to compute the local calendar-day boundary for any local-day-scoped figure. The app errors if `TZ` is unset rather than defaulting to UTC, since a silent UTC fallback would reproduce the same wrong-boundary bug without any signal that it happened. Resolving the named zone (including its DST transitions) requires the `tzdata` dependency, since Elixir's default `Calendar.UTCOnlyTimeZoneDatabase` only understands `Etc/UTC`.

## Considered Options

- **Stay UTC-only** — consistent with the rest of the domain model and needs no new dependency, but produces an incorrect "today" for a user far from UTC.
- **Fixed numeric UTC offset constant** (e.g. `+13:00`) — no `tzdata` dependency needed, but silently wrong across the twice-yearly DST transition.
- **Per-user timezone setting** — over-engineered; this app has no User/tenant concept, it's single-user.

## Consequences

- This is the first local-time concept in an otherwise UTC-only domain model. Existing UTC-based day boundaries (e.g. Timing-Derived Earned Total's since-Activated-At boundary) are unaffected and remain UTC unless separately revisited.
- New dependency: `tzdata`, which by default periodically checks IANA for new tz-database releases over HTTPS (via `hackney`) so DST rule changes stay current without a redeploy; this can be disabled with `config :tzdata, :autoupdate, :disabled` if that outbound traffic is undesired.
- New required env var, `TZ`, alongside the existing `TIMING_API_KEY` — both must be documented in the README.
