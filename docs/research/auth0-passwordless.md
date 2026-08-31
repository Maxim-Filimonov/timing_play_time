# Research: Auth0 passwordless email-code viability

**Ticket:** [#21](https://github.com/Maxim-Filimonov/timing_play_time/issues/21) (wayfinder:research) — parent map [#20](https://github.com/Maxim-Filimonov/timing_play_time/issues/20)
**Date:** 2026-08-31
**Author:** research agent (for Maxim-Filimonov)

## TL;DR verdict

**The map's Auth0 approach survives.** Both hard blockers clear:

- **Q1 (Email Code exists, not legacy-only): YES.** Passwordless "email" is a current, first-class connection type with a one-time-code (OTP) method distinct from magic link. No deprecation notice found on any Auth0 primary source.
- **Q3 (lock an app to exactly one connection): YES.** Connections are enabled per-application; you can enable only the passwordless-email connection for the app's client and leave the default `Username-Password-Authentication` database connection and all social connections disabled for that client.

Secondary answers: passwordless is included on the **Free** plan (25,000 MAU) — no paid tier required (Q2). The recommended Elixir path is **generic OIDC via `oidcc` + `oidcc_plug`** (actively maintained by the Erlang Ecosystem Foundation, OpenID-certified) rather than the near-abandoned `ueberauth_auth0` (Q4). Code entry can be either on Auth0's hosted Universal Login page **or** in the app's own UI via the Authentication API — for a Regular Web App the token exchange is a server-side back-channel call with `client_secret`, no custom domain or cross-origin machinery needed (Q5). The `sub` claim is an opaque `email|<hex-id>` assigned at user creation and is stable for the life of that user record; note the nuance in Q6 below (Auth0 does not let you *change* the email on a passwordless-email user — a different email is simply a different user with a different `sub`).

Caveat on method: several Auth0 Community threads referenced below could not be fetched directly (404 via the fetch tool) and are cited from search-result summaries; where that is the case it is called out inline. Everything load-bearing for the verdict is backed by an `auth0.com/docs`, `auth0.com/pricing`, or `hex.pm`/GitHub primary page.

---

## Q1 — Does passwordless "Email Code" still exist as a distinct connection, on new tenants, not deprecated?

**Answer: YES.**

- Auth0's passwordless overview describes email-based passwordless with **two distinct methods**: "one-time passwords ... single-use codes known as one-time passwords (OTP)" and "magic links ... a link sent to their email." They are documented separately with separate configuration resources and no deprecation banner.
  Source: <https://auth0.com/docs/authenticate/passwordless>
- Passwordless is "treated as a unique connection type in your tenant, separate from other database, social, or enterprise connections," and "user profiles are created on the passwordless connection using Auth0 as the Identity Provider."
  Source: <https://auth0.com/docs/authenticate/passwordless> and <https://auth0.com/docs/authenticate/passwordless/authentication-methods/email-otp>
- The Email OTP method doc is current and describes the live flow ("When a new user receives an OTP and enters it for the first time on your website, their user profile is created on the `email` connection before being authenticated by Auth0"). No "legacy tenant only" or "deprecated" wording anywhere on the page.
  Source: <https://auth0.com/docs/authenticate/passwordless/authentication-methods/email-otp>
- Configured from **Dashboard → Authentication → Passwordless**, "enable the Email toggle" — this is the standard new-tenant Dashboard surface, not a legacy toggle.
  Source: <https://auth0.com/docs/authenticate/passwordless/authentication-methods/email-otp>
- The New Universal Login experience "natively supports Passwordless connections" and can be configured so users "authenticate with a magic link or one-time password (OTP) through email."
  Source: <https://auth0.com/docs/authenticate/login/auth0-universal-login/passwordless-login/email-or-sms>
- Searched the Auth0 changelog / deprecations feed for 2024–2026 entries about passwordless / email OTP / email code / magic link deprecation: **none found**. (Absence of a deprecation notice is not a positive guarantee, but there is no primary-source evidence of removal or legacy-gating.)
  Source: <https://auth0.com/changelog>

**Not a "no".**

---

## Q2 — Plan and pricing

**Answer: Passwordless email is available on the Free plan. No paid tier required for a handful of users.**

- Auth0 pricing (2026) tiers: **Free — $0/mo, up to 25,000 MAU**; Essentials — from $35/mo (B2C) / $150/mo (B2B), starting at 500 MAU; Professional — from $240/mo (B2C) / $800/mo (B2B); Enterprise — custom.
  Source: <https://auth0.com/pricing>
- The pricing feature comparison lists **Passwordless as "Included" across all four tiers, Free included.**
  Source: <https://auth0.com/pricing>
- Corroborated by multiple secondary summaries (G2, SaaSworthy, CostBench, IDSync) all reporting Free = 25,000 MAU with passwordless included in 2026. These are secondary and cited only as corroboration.

**Cost for this app (owner + a small known group, well under 25,000 MAU): $0/month on Free.** MAU is billed as users who authenticate through Auth0 in a 30-day window; since Auth0 is only touched during link/login flows (map constraint #7), MAU here is roughly "people who logged in or re-linked this month" — a handful, far inside the free allowance.

One thing to confirm at build time against the live Dashboard, not resolvable from docs: whether the Free plan imposes any cap on the number of Auth0 **Actions** or custom email template customisation you might want. Not a blocker for the minimal flow.

---

## Q3 — Can a tenant/application be locked to exactly one connection (passwordless email), social + username-password disabled?

**Answer: YES.**

- Connections are enabled/disabled **per application**: "Go to Dashboard → Applications → [your app] → **Connections** tab, and enable or disable the appropriate connections for the application."
  Source: <https://auth0.com/docs/get-started/applications/update-application-connections>
- Equivalently, from the connection side, each connection has an `enabled_clients` list (Management API `PATCH /api/v2/connections/{id}`) controlling which applications may use it.
  Source (mechanism named): <https://auth0.com/docs/get-started/applications/update-application-connections>; Pulumi/Terraform `auth0_connection` resources expose `enabled_clients` — <https://www.pulumi.com/registry/packages/auth0/api-docs/connection/>
- A newly created tenant ships with a default `Username-Password-Authentication` database connection, and new applications are auto-enabled on existing connections; Auth0's own support article "Unwanted Connections Enabled on Newly Created Applications" documents how to turn those off per app.
  Source: <https://support.auth0.com/center/s/article/New-applications-get-enabled-on-unwanted-connections>
- Community threads "Disable all but one connection when creating a new application" and "Restrict client to a specific connection upon creation" confirm this is the standard approach (disable the DB connection and every social connection for that client, leave only the passwordless-email connection enabled). *(Cited from search summaries — the thread pages 404'd via the fetch tool. community.auth0.com/t/disable-all-but-one-connection-when-creating-a-new-application/55132)*
- The docs place no "minimum one of each type" requirement; there is no rule forcing a database or social connection to remain enabled.
  Source: <https://auth0.com/docs/get-started/applications/update-application-connections>

**Practical setup for the map:** one Auth0 tenant, one Regular Web Application, one passwordless `email` connection with `enabled_clients = [that app]`; the default DB connection and any social connections left with that app **not** in their enabled list (or deleted entirely if the tenant is dedicated to this use). Result: the only credential the app's Universal Login / Authentication API will accept is an emailed OTP. This satisfies map constraint #9 (one connection → one `sub` per human).

**Not a "no".**

---

## Q4 — Phoenix/Elixir integration path

**Recommendation: generic OIDC authorization-code flow via [`oidcc`](https://hex.pm/packages/oidcc) + [`oidcc_plug`](https://hex.pm/packages/oidcc_plug).** Do **not** use `ueberauth_auth0`.

| Library | Latest release | Maintenance | Notes |
|---|---|---|---|
| `oidcc` | **3.9.0 — 2026-08-30** | Active. Maintained by the **Erlang Ecosystem Foundation** Security WG (`erlef/oidcc`, owner `maennchen`). **OpenID Certified** for multiple Relying-Party conformance profiles. | "OpenID Connect client library for the BEAM." Supports auth-code flow, PKCE, code→token exchange against any standards-compliant OP (Auth0 included). <https://hex.pm/packages/oidcc>, <https://github.com/erlef/oidcc> |
| `oidcc_plug` | **0.5.1 — 2026-08-04** | Active, same org. | "Plug Integration for the oidcc OpenID Connect Library" — "Integrations for plug and phoenix." Phoenix uses Plug, so this drops in. <https://hex.pm/packages/oidcc_plug> |
| `ueberauth_auth0` | **2.1.0 — 2022-10-27** (last commit 2023-01-29) | **Effectively unmaintained** — ~4 years since last release, ~3.5 years since last commit. Open issues + PRs sitting. | Ueberauth OAuth2 strategy for Auth0. Works, but stale; no passwordless-specific handling, and you would be pinning identity infrastructure to a dormant dependency. <https://hex.pm/packages/ueberauth_auth0>, <https://github.com/achedeuzot/ueberauth_auth0> |

Why generic OIDC fits the map:

- Map constraint #7 wants Auth0 as a **credential gate only** — a plain server-side redirect to Auth0's `/authorize`, a callback that exchanges the code for an ID token, read `sub` + `email` claims, then the app sets its **own** `Plug.Session` cookie exactly as ADR-0006 already does. No token storage, no refresh, no per-request validation. `oidcc` does exactly this one job.
- Auth0 is a conformant OIDC provider, so there is nothing Auth0-specific to a strategy library here beyond the issuer URL, `client_id`, and `client_secret`. An "Auth0 SDK" would add machinery the map explicitly rules out of scope.
- `oidcc` is BEAM-native, certified, and released *yesterday* relative to this research — the maintenance bar the ticket asks for is clearly met.

Auth0 also publishes a Phoenix quickstart built on `ueberauth` + `ueberauth_auth0`; given that strategy's dormancy, treat the quickstart as reference only, not the dependency choice.
Source: <https://auth0.com/docs/quickstart/webapp/phoenix>

For the **test** environment (map constraint #10): none of this changes the plan — a behaviour + stub adapter selected in `config/test.exs` stands in for the OIDC round-trip; `oidcc` is only wired in for dev/prod.

---

## Q5 — Code entry surface: Auth0 hosted page, or our own UI?

**Answer: BOTH are supported. For the map, the hosted Universal Login page is the low-effort default and needs no code-entry screen; an in-app code screen is possible but pulls in the Authentication API.**

**Option A — Universal Login (recommended, matches "plain server-side OIDC redirect"):**
- The app redirects to Auth0; the user requests and enters the OTP on **Auth0's hosted page**; Auth0 redirects back to the app's callback with an authorization code.
- "Passwordless Authentication with Universal Login" is "the preferred way to implement Passwordless Authentication." The New Universal Login experience "natively supports Passwordless connections."
  Sources: <https://auth0.com/docs/authenticate/passwordless/implement-login/universal-login>, <https://auth0.com/docs/authenticate/login/auth0-universal-login/passwordless-login/email-or-sms>
- **Implication for downstream / the prototype ticket: with Option A the app builds NO code-entry UI.** It builds a "Link email" button and a callback route. The email field (to prefill / hint the connection) can be passed as `login_hint`.

**Option B — Embedded login (code entered in the app's own LiveView UI):**
- `POST /passwordless/start` sends the code; `POST /oauth/token` with grant type `http://auth0.com/oauth/grant-type/passwordless/otp` (params `client_id`, `client_secret`, `username` = email, `otp`, `realm` = `email`) exchanges the entered code for tokens.
  Source: <https://auth0.com/docs/authenticate/passwordless/implement-login/embedded-login/relevant-api-endpoints>
- "You cannot use this endpoint from Single Page Applications." **Native Applications and Regular Web Applications** can. For a web app the **`client_secret` is required** — i.e. this is a server-side back-channel call, which is exactly what a Phoenix backend does. No custom domain and no cross-origin/CORS setup is needed when the call originates server-side (cross-origin authentication only applies when a browser SPA calls Auth0 directly).
  Source: <https://auth0.com/docs/authenticate/passwordless/implement-login/embedded-login/relevant-api-endpoints>
- You must enable the **Passwordless OTP** grant for the application (Dashboard → Applications → [app] → Advanced Settings → Grant Types). Community threads titled "Grant type 'http://auth0.com/oauth/grant-type/passwordless/otp' not allowed for the client" are all this missing toggle. *(thread titles from search; the grant-enable requirement itself is from the docs page above.)*
- Trade-off: Option B means the app owns the code-entry screen, resend logic, error states ("wrong code", "expired", "too many attempts"), and rate-limit handling — re-implementing UX that Universal Login gives for free. It also does not go through the OIDC `/authorize` redirect, so it is a poorer fit for `oidcc` and for map constraint #7's "plain redirect flow" framing.

**Recommendation to unblock the prototype ticket:** design for **Option A**. The prototype does not need a code-entry screen — only a redirect out and a callback in. Keep Option B in the back pocket only if product later insists the user must never leave the app's own pages.

OTP behaviour (either option), useful for prototype copy/timeouts:
- Code valid **3 minutes** by default; only the most recently issued code works; **3 failed attempts** then the user must request a new code.
  Source: <https://auth0.com/docs/authenticate/passwordless/authentication-methods/email-otp>
- The connection has a **"Disable Sign Ups"** option to restrict to existing users (docs note this can expose user-enumeration — aligns with the map's out-of-scope "if that email is linked, we sent a code" stance).
  Source: <https://auth0.com/docs/authenticate/passwordless/authentication-methods/email-otp>

---

## Q6 — Is `sub` stable across an email change within the passwordless email connection?

**Answer: `sub` is stable for the life of a user record — BUT Auth0 does not support changing the email on a passwordless-email user, so "email change within the connection" is not really an operation. A different email = a different user = a different `sub`.**

Details:

- `sub` is populated from the user's `user_id`, format `[provider]|[local part]`. When the local part is not explicitly set at creation it is "a hexadecimal string (for example, `5c6b52fd451bd02197ecbd5f`)" — i.e. an **opaque id generated at user-creation time, not derived from the email**. For the passwordless email connection the `sub` looks like `email|<hex-id>`.
  Source: <https://support.auth0.com/center/s/article/Documentation-regard-ID-Token-sub-claim-is-unclear>
- Because the hex id is minted once at creation and never recomputed, `sub` does not change for that user row over its lifetime. Auth0's guidance is consistently "use `sub` as the stable user key."
  Sources: <https://support.auth0.com/center/s/article/Documentation-regard-ID-Token-sub-claim-is-unclear>, <https://auth0.com/docs/get-started/apis/scopes/sample-use-cases-scopes-and-claims>
- **The nuance that matters for map constraint #8:** multiple Auth0 Community threads report that the Management API **rejects an email update on a passwordless (email) connection user** — error "Cannot update email for this user" — and that changing it is only possible if the user also has a username-password identity. *(Cited from search-result summaries of community.auth0.com threads "Cannot update user email for Passwordless flow" /98805 and "Change passwordless user email" /21681; one thread had a brief Auth0-staff acknowledgement but no staff technical contradiction. Could not fetch the thread bodies directly — treat as strong indication, not a documented guarantee.)*
- Consequence: within a single passwordless-email connection, a human who starts using a new email address does **not** get their existing profile's email rewritten — the next login with the new address **creates a new user with a new `sub`**. Auth0's own passwordless docs acknowledge this shape: "as you cannot ensure users will log in with the same email ... every time, users may end up with multiple user profiles."
  Source: <https://auth0.com/docs/authenticate/passwordless>

**What this means for the map:**

- Map constraint #8 ("`email` is a denormalised display attribute only, never used for lookup; join on `auth0_sub`") is **still correct and, if anything, more strongly justified** — `sub` is the only stable handle, and it is genuinely opaque and immutable per user row.
- The map's stated *rationale* ("Auth0 emails can change, `sub` cannot") is slightly off: within passwordless email, Auth0 emails effectively **cannot** change either — a new email is a new identity. The design should treat "user changed their email" as "user links a second time from a new address, producing a new `sub`", which lands squarely in **map constraint #5's switch-never-merge collision policy** (new `sub` → new or switched User; old anonymous/previous User left orphaned if non-empty, never silently merged). Worth a one-line note in the ADR so the spec author does not assume an in-place email-update path exists.
- No change needed to the `auth0_sub` column design. The `email` column remains a display-only denormalisation refreshed from the ID token's `email` claim on each successful login.

---

## Sources

Primary (Auth0 first-party):
- <https://auth0.com/docs/authenticate/passwordless>
- <https://auth0.com/docs/authenticate/passwordless/authentication-methods/email-otp>
- <https://auth0.com/docs/authenticate/passwordless/implement-login/universal-login>
- <https://auth0.com/docs/authenticate/passwordless/implement-login/embedded-login>
- <https://auth0.com/docs/authenticate/passwordless/implement-login/embedded-login/relevant-api-endpoints>
- <https://auth0.com/docs/authenticate/login/auth0-universal-login/passwordless-login/email-or-sms>
- <https://auth0.com/docs/get-started/applications/update-application-connections>
- <https://auth0.com/docs/get-started/apis/scopes/sample-use-cases-scopes-and-claims>
- <https://auth0.com/docs/quickstart/webapp/phoenix>
- <https://auth0.com/pricing>
- <https://auth0.com/changelog>
- <https://support.auth0.com/center/s/article/Documentation-regard-ID-Token-sub-claim-is-unclear>
- <https://support.auth0.com/center/s/article/New-applications-get-enabled-on-unwanted-connections>

Primary (Elixir library sources):
- <https://hex.pm/packages/oidcc> · <https://github.com/erlef/oidcc>
- <https://hex.pm/packages/oidcc_plug>
- <https://hex.pm/packages/ueberauth_auth0> · <https://github.com/achedeuzot/ueberauth_auth0> (last commit 2023-01-29 via GitHub API)

Secondary / not directly fetchable (cited as indication only, flagged inline):
- community.auth0.com threads: "Cannot update user email for Passwordless flow" (/98805), "Change passwordless user email" (/21681), "Disable all but one connection when creating a new application" (/55132), "Grant type ... passwordless/otp not allowed for the client" (/36678)
- Pricing corroboration: G2, SaaSworthy, CostBench, IDSync (2026 Auth0 pricing summaries)
