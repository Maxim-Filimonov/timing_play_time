# Multi-tenant accounts via anonymous session cookies

**Status**: accepted

Reverses [ADR-0005](0005-local-timezone-for-day-boundaries.md)'s premise that "this app has no User/tenant concept, it's single-user" — that was true at the time but is no longer the direction. The app becomes multi-tenant with full data isolation: `activities`, `manual_syncs`, and `playtime_used` all become scoped to a `User`. Rather than building real accounts (email/password, magic-link, etc.), identity is a long-lived, encrypted, HttpOnly session cookie holding an opaque `user_id` — the cookie *is* the account. First visit silently provisions a `User` row and sets the cookie; there is no login screen and no credential recovery. Losing the cookie (clearing browser data, switching browsers) means unrecoverable loss of that user's Activities and Play Balance. This is an accepted tradeoff for a starter/personal-scale app — real accounts can be layered in later if the loss-of-access failure mode becomes a real problem, without changing the underlying tenant-isolation shape.

## Considered Options

- **Real accounts with login** (magic-link email, no passwords) — recoverable across devices and cookie loss, but a login flow is more than this app needs at its current scale; deferred, not ruled out permanently.
- **Settings/credentials stored directly in the cookie payload** (encrypted) rather than pointing at a DB row — rejected: still needs a `users` table anyway (Activities/Play Balance/Manual Syncs need an owner to foreign-key against), so splitting settings into the cookie bought nothing while adding a ~4KB payload ceiling, secrets replayed on every request, and hand-rolled crypto that `Plug.Session`'s existing cookie store already provides for free once `encryption_salt` is set.

## Consequences

- New `users` table (id, `timezone`, timestamps). No password/email column — identity is the cookie alone.
- `Plug.Session` cookie store (`lib/timing_play_time_web/endpoint.ex`) gains `encryption_salt` (encrypted, not just signed), a fixed `max_age` of ~1 year (not sliding/refreshed-on-visit), and `secure: true` gated to non-dev/test environments (no local TLS in dev). `HttpOnly` and `SameSite=Lax` were already in place. The cookie carries only the `user_id` pointer, never settings or secrets.
- `TZ` moves from a required boot-time env var (ADR-0005's mechanism) to a `users.timezone` column, auto-populated via browser `Intl.DateTimeFormat` detection on first visit rather than an onboarding gate or a silent UTC default — a silent UTC default would reintroduce exactly the "wrong day boundary with no signal" failure ADR-0005 was written to avoid, so the replacement had to produce a genuinely correct value, not a placeholder. ADR-0005's actual subject — using an IANA timezone name and the `tzdata` dependency to compute local calendar-day boundaries — is unchanged and still correct; only the delivery mechanism (env var → per-user column) and its "single-user" framing are superseded.
- Existing single-user data (`activities`, `manual_syncs`, `playtime_used`) is backfilled onto one default `User` via migration, with a one-time manual step required post-deploy to link the operator's own browser to that `user_id`.
