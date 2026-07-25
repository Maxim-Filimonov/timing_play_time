# Pluggable persistence, backed initially by Fibery

**Status**: accepted

Activity configuration (multiplier, mapped Timing Project, activated-at timestamp) and the app's own records (Manual Sync values, Playtime Used log) need a durable store. Rather than reaching for a conventional database, we're using the already-connected Fibery MCP Server as the initial backend, since it gives us a queryable store with zero setup. To avoid lock-in to a no-code tool for what is fundamentally simple structured data, persistence is accessed only through a repository/port interface defined by this app — the Fibery-backed implementation is one adapter behind that interface, not something the domain or UI code talks to directly. Swapping in Postgres or SQLite later means writing a new adapter, not touching call sites.

## Consequences

- All persistence access must go through the port interface — no direct Fibery MCP calls from domain or UI code.
- Fibery's schema (databases/entities/fields) needs to model Activities, Manual Sync state, and Playtime Used log entries; this mapping lives entirely inside the Fibery adapter.
