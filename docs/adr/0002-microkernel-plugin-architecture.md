# Microkernel / plug-in architecture for external integrations

**Status**: accepted

Both external integrations this app depends on — the time source (Timing) and the persistence store (Fibery, per [ADR-0001](0001-pluggable-persistence-via-fibery.md)) — are swapped out behind plug-in interfaces rather than called directly, following a microkernel (plug-in) architecture. The core owns the domain logic (Play Balance computation, Activity configuration, Playtime Used log) and defines the plug-in contracts; each integration is an adapter implementing one of those contracts and is not otherwise privileged over a future alternative adapter.

Two plug-in points exist initially:

- **Time Source plug-in** — reports elapsed duration for a given external project/activity identifier since a given timestamp. Initial adapter: Timing, via its MCP server.
- **Persistence plug-in** — stores and retrieves Activities, Manual Sync state, and the Playtime Used log. Initial adapter: Fibery, via its MCP server (ADR-0001).

Core domain code (Play Balance computation, CLI/web handlers) depends only on these two contracts, never on the Timing or Fibery MCP tools directly.

## Consequences

- Adding a second time source (e.g. a different tracker, or a plain manual-entry source) or a second persistence backend means writing a new adapter against the existing contract, not changing core logic.
- The plug-in contracts themselves become the thing to get right early — changing a contract's shape later means updating every adapter behind it. In particular, when a contract fetches data per-entity from a slow external system, design it batched (entity list in, not one entity) from the start — see [ADR-0009](0009-batch-per-entity-adapter-calls-to-avoid-n-plus-1.md).
