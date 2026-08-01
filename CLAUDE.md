## Agent skills

### Issue tracker

Issues live as GitHub Issues in `Maxim-Filimonov/timing_play_time`, managed via the `gh` CLI. See `docs/agents/issue-tracker.md`.

### Triage labels

Default vocabulary (`needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`) mapped 1:1 to GitHub labels of the same names. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context layout — `CONTEXT.md` + `docs/adr/` at the repo root. See `docs/agents/domain.md`.

### Writing agent-ready specs

What made issue #7 a clean one-shot `/implement` (exact contract signatures, pre-resolved design decisions, per-file testing decisions, an explicit out-of-scope list) — and a checklist for writing the next one the same way. See `docs/agents/ready-for-agent.md`.
