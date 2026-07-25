# SQLite via Ecto as the initial persistence backend

**Status**: accepted

Supersedes [ADR-0001](0001-pluggable-persistence-via-fibery.md)'s choice of Fibery as the initial persistence adapter. Fibery was picked for "zero setup," but Phoenix's own generator already scaffolds Ecto and SQLite in this repo (dependencies, `Repo`, per-environment database config, sandbox test mode) — it's Fibery that would now require genuinely new setup (schema modeling in a no-code tool, MCP wiring), not SQLite. The persistence port and microkernel architecture from ADR-0001/ADR-0002 are unchanged: SQLite is simply the first concrete adapter behind `TimingPlayTime.Plugins.Persistence`, and Fibery remains a planned second adapter (tracked in issue #2).

## Consequences

- The adapter is named `TimingPlayTime.Plugins.Persistence.Sqlite` (named for the backend, not the `Ecto` library, since `Repo` is hardcoded to `Ecto.Adapters.SQLite3` and a future Postgres adapter would also be Ecto-based).
- Primary keys are `binary_id` (`Ecto.UUID`), matching the existing Stub adapter's opaque-string-ID contract.
- Manual Sync is modeled as an append-only log (each sync inserts a row; the adapter reads the latest by timestamp) rather than a single mutable row — same external behavior (overwrite semantics), plus a free audit trail.
- A shared persistence contract-test suite is introduced, run against both `Stub` and `Sqlite` (and later `Fibery`), to keep adapters behaviorally identical behind the `@callback` contract.
- `config/config.exs`'s default `persistence_adapter` becomes `Persistence.Sqlite` for dev/prod; `config/test.exs` continues to override to `Persistence.Stub` for fast, DB-free domain tests.
