# Playtime

Converts real-world time spent on worthwhile activities (tracked in the Timing app) plus manually-synced exercise time into a balance of earned play time, which is spent down by logging play sessions.

See `CONTEXT.md` for the domain glossary and `docs/adr/` for architectural decisions.

## Running the app

The app is multi-tenant (see [ADR-0006](docs/adr/0006-multi-tenant-anonymous-cookie-accounts.md)): each browser gets its own anonymous account on first visit, with its own timezone and Timing API key set via the in-app Settings page (`/settings`) rather than env vars — `TIMING_API_KEY` and `TZ` are no longer used.

One environment variable is required outside `dev`/`test` (which use a committed default, the same way `secret_key_base` works):

- **`CLOAK_KEY`** — a base64-encoded 32-byte key used to encrypt Integration credentials at rest (see [ADR-0007](docs/adr/0007-generic-per-user-integration-credentials.md)). Generate one with `32 |> :crypto.strong_rand_bytes() |> Base.encode64()`. There's no key-rotation tooling yet — losing or changing this key makes every stored credential permanently undecryptable.

```
mix setup   # first time only: deps, db, assets
mix phx.server
```

Then visit [`localhost:4000`](http://localhost:4000) and set your timezone/Timing API key at `/settings` (timezone is also auto-detected from your browser on first visit).

### Auth0 dev tenant (optional email linking — WIP)

The optional email-linking feature (map [#20](https://github.com/Maxim-Filimonov/timing_play_time/issues/20)) needs each developer to have their own Auth0 dev tenant restricted to passwordless email. Run:

```
scripts/auth0-dev-setup.sh
```

It walks you through creating the tenant and application, locking it to the passwordless email (one-time code) connection, and writes `AUTH0_DOMAIN`, `AUTH0_CLIENT_ID`, `AUTH0_CLIENT_SECRET`, and `AUTH0_CALLBACK_URL` to a gitignored `.env`. The anonymous-first flow never touches Auth0, so this is only needed to work on the login/link paths.

Learn more about the underlying Phoenix framework:

  * Official website: https://www.phoenixframework.org/
  * Guides: https://hexdocs.pm/phoenix/overview.html
  * Docs: https://hexdocs.pm/phoenix
  * Forum: https://elixirforum.com/c/phoenix-forum
  * Source: https://github.com/phoenixframework/phoenix
