# Hierarchical source picker, backed by a `list_sources/1` plugin capability

**Status**: accepted

## Context

An Activity maps to one external tracked entity by identifier, stored in the
`activities.time_source_identifier` column. Today both the Add and the Edit
Activity forms on the dashboard LiveView collect that identifier as a
**free-text field labelled "Timing Project"** — the user has to know, and
correctly type, a Timing Project id (or a name the adapter can match). Two
problems:

- **It leaks the provider.** The field is labelled for Timing specifically,
  even though `TimeSource` is a plugin boundary (ADR-0002) with a Stub
  adapter and a planned second provider. Nothing about the Activity form
  should assume the source is Timing.
- **It's blind.** There is no way to see what sources exist. A typo, a
  renamed Project, or a guessed id silently produces an Activity that earns
  nothing, and the dashboard card shows only the raw id.

The `TimeSource` behaviour already knows how to *read time* for a set of
Activities (`get_elapsed_minutes/2`, `list_entries/2`, both batched per
ADR-0009), but it has no way to *enumerate the sources* a user could pick
from. Adding that is what unblocks a real picker.

Research (issue #27, `docs/research/timing-mcp-list-projects.md`, confirmed
live against `https://web.timingapp.com/mcp`) established the Timing side:
`list_projects` returns **every** non-archived project in **one** call, each
row carrying a bare-id `self`, `title`, `is_archived`, and `parents: [{self,
title}]` — the **immediate parent only**, no ancestor chain, no
`title_chain`. Hierarchy has to be reconstructed adapter-side by walking
`parents[0].self` across the flat result. A prototype (issue #28,
`/dev/proto/source-picker`) settled the interaction: a flat "path" dropdown,
pure LiveView, with a manual-id fallback.

## Decision

**1. New `TimeSource` callback — `list_sources/1`.**

```elixir
@callback list_sources(opts :: keyword()) ::
            {:ok, [source]} | {:error, :not_connected} | {:error, term()}

@type source :: %{
        id: String.t(),
        title: String.t(),
        ancestors: [String.t()],
        depth: non_neg_integer()
      }
```

- `opts[:client]` is the caller-owned live connection, same convention as
  `get_elapsed_minutes/2` / `list_entries/2`. No `:client` ⇒
  `{:error, :not_connected}`.
- The returned list is **flat, pre-order DFS** — every parent immediately
  followed by its own subtree — **alphabetical by title within a level**.
  Archived sources excluded.
- `ancestors` is the list of ancestor **titles**, root-first; `depth ==
  length(ancestors)`. The adapter owns hierarchy construction; core never
  sees a nested tree, and never re-sorts.

**2. Storage — the picked id, plus a label snapshot.**

- The picked value is stored as the **bare source id** in
  `time_source_identifier` — no format change. The Timing adapter already
  normalises `/projects/<id>` vs bare ids (`strip_projects_prefix/1`) when
  matching entries, and `list_time_entries`' `projects[]` filter accepts the
  bare id (verified live, #27).
- A **new nullable `time_source_label` column** on `activities` holds the
  flattened path string (`"Edu → Coding"`) captured **at pick time**. It is
  rendered on the Activity card. It is **never auto-refreshed** — the user
  sees the label they picked even if the source is later renamed or deleted
  upstream. No backfill of existing Activities: the column is nullable and
  the card falls back to showing the id.

**3. Fallback — one "manual id" mode.**

The picker degrades to a bare text input (no dropdown, stores whatever is
typed) when the source list is unavailable: no integration configured, or
`list_sources/1` returns `{:error, _}` or `[]`. An always-visible toggle
also switches into it deliberately. A zero-match filter shows a "no match —
switch to manual entry" hint. Edit preselects the picker when the stored id
matches a returned source, else opens in manual mode showing the current
value.

**4. UI — in place, pure LiveView, no new page.**

Both forms on `dashboard_live.html.heex`; Settings has no activity
management. The picker is a **`LiveComponent`** (a bare `phx-change` needs a
`<form>` and the picker sits inside the outer Activity form — forms can't
nest): `phx-keyup` drives filtering and optional key-nav, `phx-target={@myself}`
keeps its state off the parent, Add and Edit embed it identically. Sources
are fetched **async after first render** (`assign_async` / `start_async`),
cached in the component's assigns, only when an integration is configured —
keeping `list_sources/1` off the mount critical path (ADR-0007 / ADR-0009's
"how many external calls does one page-load make" concern). One small JS
assist is required: after a keyboard Enter-select, LiveView won't overwrite
the still-focused input's DOM value, so blur-on-select via
`Phoenix.LiveView.JS` or a tiny value-writing hook.

Filter: case-insensitive; whitespace-split into tokens that must **all**
appear somewhere in the full ancestors+title path (AND, order-independent);
a single token is a plain substring test. Every node is selectable (parent
projects hold time too). Full list on focus; all matches; no result cap; no
minimum query length. Arrow-key / Enter nav is a SHOULD, not a MUST — each
keypress is a server round-trip.

## Considered options

- **Nested-tree return type** (`%{id, title, children: [...]}`). Rejected:
  every consumer (filter, flat dropdown render, "is this id still a valid
  source" check) wants the flat form, and would have to re-flatten. The
  adapter is the one place that has the parent links in hand, so it does the
  DFS+sort once. The flat-list-with-`depth` shape keeps structure available
  (indentation is a deferred enhancement) without forcing a tree walk on
  core.
- **Timing-only, no contract change** — special-case a
  `Timing.list_projects` call in the LiveView. Rejected: it re-buries the
  provider assumption the picker exists to remove, and the Stub (and a
  future second provider) get no picker. The capability belongs on the
  behaviour.
- **Hard replace of the free-text field, no fallback.** Rejected: a user
  with no integration configured, or a transient `list_sources/1` failure,
  would be unable to create or edit an Activity at all. The manual-id mode
  keeps the form usable in every state, at the cost of one toggle.
- **Auto-refreshing `time_source_label`** (re-derive from the live source on
  every render, or drop the column and always show the current upstream
  title). Rejected: an upstream rename or deletion would silently change or
  blank the label under the user. The snapshot is intentional — it records
  what they picked.
- **Backfill existing Activities' `time_source_label`** on migration.
  Rejected as unnecessary: the column is nullable and the card already has a
  sensible fallback (the id). Existing Activities pick up a label the next
  time they're edited.

## Consequences

- `TimeSource` gains a third capability. Both adapters implement it: the
  Timing adapter with a live `list_projects` call + a client-side
  `parents[0].self` walk to build `ancestors`/`depth`; the Stub with a fixed
  2-level hierarchy whose leaf ids keep the rate-matching prefixes
  (`Development → coding-app`, …) so `Stub.daily_rate/1` still resolves.
- One schema migration: `add :time_source_label, :string, null: true` on
  `activities`. No data migration.
- The Activity form no longer names a provider. `CONTEXT.md` gains a
  **Source** glossary entry (Source = the pickable external entity; "Timing
  Project" is Timing's name for it; `time_source_identifier` is the stored
  id), and the **Activity** entry's _Avoid: Project_ note is reworded away
  from "Timing Project" as the field label.
- A batched-vs-N+1 review (ADR-0009) is not triggered: `list_sources/1` is
  one call regardless of Activity count — it enumerates the provider's
  sources, not per-entity data.
- Large project counts are accepted as-is for v1 — no dropdown
  virtualisation, no result cap. Indented/visually-nested rendering is
  deferred (the flat "→" path is v1). Multi-select is out — one Source per
  Activity, unchanged.
