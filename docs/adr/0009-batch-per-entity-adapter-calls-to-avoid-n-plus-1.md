# Batch per-entity external API calls to avoid N+1, especially for slow/async APIs

**Status**: accepted

## Context

The Timing adapter originally called `list_time_entries` once (or twice —
cumulative and today) *per Activity*, because the original `TimeSource`
contract (ADR-0002) took a single Activity. That's a classic N+1: work that's
O(1) round-trips in shape (one dashboard load) became O(N) round-trips in
practice (N = a User's Activity count), each one a real network call to an
external MCP server. It wasn't hypothetical — a User with several Activities
could trigger enough sequential round-trips to blow past the LiveView
longpoll transport's 10-second reply window and drop the connection
("Something went wrong! Attempting to reconnect"). ADR-0008 records the fix:
batching to one call per dashboard load.

This ADR generalizes the lesson so the next adapter (a second Time Source,
the Fibery persistence adapter, anything else that fans out per-domain-entity
calls to a slow external system) doesn't reintroduce the same shape and have
to be retrofitted the same way.

## Decision

When a plug-in adapter (per ADR-0002's microkernel boundary) needs data for
N domain entities from an external system, and that system is reached over
the network — slow, async, rate-limited, or otherwise not free per call —
**design the plug-in contract to take the entity list and fetch in one
batched call from the start**, not one call per entity with batching added
later. Concretely:

- Before writing a `@callback` for a new adapter, check whether the external
  API supports a multi-ID / multi-filter query (Timing's `list_time_entries`
  already accepted multiple `projects` — the *contract* just hadn't been
  designed to use it). If it does, the contract's first parameter is a list,
  not a single entity, even if every call site today only ever has one
  entity in hand.
- If the external API genuinely has no batch endpoint, the contract can
  still take a list — the adapter loops internally (see `TimeSource.Stub`,
  which implements the same plural contract by looping, since it has no real
  network cost to batch away). The *cost* of N calls doesn't disappear, but
  the *contract* stays uniform, so a future adapter that *can* batch doesn't
  need a breaking contract change to do it.
- Treat "how many real external calls does one page-load/action make" as a
  reviewable property of the design, the same way you'd review a SQL N+1 —
  not something to notice only after it's slow or timing out in production.
- Where precision must be traded for batching (e.g. ADR-0008's shared
  earliest-cutoff instead of one cutoff per entity), write that trade-off
  down as its own ADR — don't let it hide as an implementation detail.

## Consequences

- Every future adapter design should ask "N+1 or one batched call?" before
  the contract's shape is settled, not after a User with enough entities hits
  a timeout.
- A batched contract sometimes costs precision (ADR-0008) or failure
  isolation (a single failed batched call now zeroes every entity's result,
  vs. isolating one bad entity) — that's an accepted, explicit trade-off to
  make consciously per-adapter, not a reason to default back to N+1.
