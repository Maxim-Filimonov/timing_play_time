# Playtime

Converts real-world time spent on worthwhile activities (tracked in the Timing app) plus manually-synced exercise time into a balance of earned play time, which is spent down by logging play sessions.

See `CONTEXT.md` for the domain glossary and `docs/adr/` for architectural decisions.

## Running the app

Two environment variables are required in every environment except `test` (which uses stub adapters and needs neither):

- **`TIMING_API_KEY`** — a personal API key from Timing's web app (API Keys section), used to fetch elapsed time per Activity via Timing's MCP server.
- **`TZ`** — an IANA timezone name (e.g. `Pacific/Auckland`), used to compute the local calendar day for day-scoped figures like each Activity's minutes earned today (see [ADR-0005](docs/adr/0005-local-timezone-for-day-boundaries.md)). There's no default — the app fails to start rather than silently compute the wrong "today".

```
export TIMING_API_KEY=...
export TZ=Pacific/Auckland

mix setup   # first time only: deps, db, assets
mix phx.server
```

Then visit [`localhost:4000`](http://localhost:4000).

Learn more about the underlying Phoenix framework:

  * Official website: https://www.phoenixframework.org/
  * Guides: https://hexdocs.pm/phoenix/overview.html
  * Docs: https://hexdocs.pm/phoenix
  * Forum: https://elixirforum.com/c/phoenix-forum
  * Source: https://github.com/phoenixframework/phoenix
