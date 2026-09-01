# Research: Timing MCP wire format for listing projects

**Ticket:** [#27](https://github.com/Maxim-Filimonov/timing_play_time/issues/27) (wayfinder:research) — parent map [#26](https://github.com/Maxim-Filimonov/timing_play_time/issues/26)
**Date:** 2026-09-01
**Author:** research agent (for Maxim-Filimonov)

## Location note

The repo's research-notes convention is `docs/research/<topic>.md` — established by ticket
[#21](https://github.com/Maxim-Filimonov/timing_play_time/issues/21) / commit `34e2479`
(`docs/research/auth0-passwordless.md`). That commit is not on this worktree's branch, so
`docs/research/` did not yet exist here; this file re-creates the directory and follows the
same file shape.

## Surfaces consulted (and how they relate)

| Surface | What it is | Auth |
| --- | --- | --- |
| **App endpoint** — `https://web.timingapp.com/mcp` via `ExMCP.Client` (HTTP transport) | The MCP server the adapter (`lib/timing_play_time/plugins/time_source/timing.ex:19`, `@mcp_url`) actually talks to. | Bearer token = the User's Integration `api_key` (`timing.ex:33`). |
| **Timing API docs** — `https://web.timingapp.com/docs/` | Timing's own published reference. ADR-0002 links it as the source of truth for the MCP tools. Lists exactly the 16 MCP tools below. | public |
| **`claude.ai Timing` connector** — `mcp__claude_ai_Timing__*` tools in this session | A live, authenticated connection to the **same** Timing account, exercised here to observe real response bytes. Tool descriptions served to this session are verbatim copies of the `web.timingapp.com/docs/` REST reference (they still carry `#projects-GETapi-v1-projects--project_id-` doc anchors and `<aside class="notice">` HTML), i.e. this connector is a thin proxy over Timing's v1 API / MCP surface. | this session's OAuth |

**Why the connector is a fair proxy for the app endpoint:** the app's own test double
(`test/support/timing_mock_handler.ex:34-40`) models a `list_time_entries` result as
`%{"time_entries" => [...], "projects" => [...], "teams" => [...]}` with entry
`project.self` in `/projects/<id>` form. The connector's live `list_time_entries` returns
**exactly** that shape (three sibling arrays; entries carry `"project": {"self": "/projects/3833165163333022720"}`).
The app endpoint and the connector are almost certainly the same MCP server. Divergence
risk is called out per-question below where it exists.

**Direct live probe — DONE (2026-09-01, follow-up).** The research agent could not reach
`https://web.timingapp.com/mcp` (no credentials in its environment). Maxim then supplied a
scoped bearer token (`scopes: ["mcp:use"]`) and the endpoint was probed directly over the
MCP streamable-HTTP transport: `initialize` → `notifications/initialized` → `tools/list` →
`tools/call`. **Every divergence risk below is now closed against the real endpoint** — see
"Direct-endpoint confirmation" at the bottom. The connector-proxy reasoning held: the app
endpoint returns byte-identical shapes.

Historical note (pre-probe): no Timing credentials were present in the agent's environment —
no `TIMING_*` env var, no `config/dev.secret.exs`, no `.env`; the key lives only as
Vault-encrypted `Integration.credentials` in a dev DB (`config/runtime.exs:23` confirms
`TIMING_API_KEY` was removed as a boot var in ADR-0006/0007). An unauthenticated
`POST https://web.timingapp.com/mcp` returns `{"message":"Unauthenticated."}`.

## The MCP tool set

`https://web.timingapp.com/docs/` (fetched 2026-09-01) enumerates the Timing MCP server's tools:

```
get_activity_hierarchy   list_projects        show_project
create_project            update_project       delete_project
list_time_entries         show_time_entry      show_latest_time_entry
show_running_timer        create_time_entry    update_time_entry
delete_time_entry         batch_update_time_entries
start_timer               stop_timer
```

The app would enumerate these with `ExMCP.Client.list_tools/1` (ex_mcp `1.0.0-rc.4`,
`mix.lock:22`) — the standard MCP `tools/list` call; the adapter today only ever calls
`ExMCP.Client.call_tool/3` (`timing.ex:159`). There is **no** dedicated
projects-hierarchy MCP tool — the REST API's `GET /projects/hierarchy` is *not* in the MCP
tool list. `list_projects` is the tool for this job.

---

## Q1 — Is there a tool for listing projects? Name + argument schema

**YES — `list_projects`.**

Argument schema (from the Timing API reference, served verbatim as the
`mcp__claude_ai_Timing__list_projects` tool description this session):

| Arg | Type | Default | Meaning |
| --- | --- | --- | --- |
| `include_archived` | boolean | `false` | "If set to `true`, archived projects will be included in the result." |
| `team_ids` | array of `string \| null` | omitted = all | "If provided, only projects from the specified teams will be returned. Include `null` in the array to include personal projects (not assigned to any team)." |

Both optional; `list_projects` with no arguments returns all non-archived projects. It
returns the **entire project list in one call** (no pagination parameter, unlike
`list_time_entries`' 1000-row cap). Observed: a single call returned all 11 of the test
account's projects.

Source: `web.timingapp.com/docs/` GET /projects ("Return a list containing all projects.");
live `mcp__claude_ai_Timing__list_projects` call.

---

## Q2 — Per-project response shape

Documented attributes (`web.timingapp.com/docs/`, "Display the specified project" — which
`list_projects` explicitly reuses: *"See ... for the returned attributes"*):

`self`, `title`, `title_chain`, `color`, `productivity_score`, `is_archived`, `parent`,
`children`, `team_id`, `default_billing_status`, `notes`, `custom_fields`.

**Observed live shape** of one project row from `list_projects` (claude.ai connector, same
account):

```json
{
  "self": "3833165163333022720",
  "title": "Coding",
  "color": "#ECDD47FF",
  "productivity_score": 1,
  "notes": null,
  "is_archived": false,
  "team_id": null,
  "parents": [{ "self": "3833165144808831232", "title": "Edu" }],
  "children": []
}
```

Field-by-field:

| Aspect | Finding | Source |
| --- | --- | --- |
| **id field** | Docs: `self` is *"a reference to the entity itself, relative to the API root"*, example `/projects/1`. **Observed:** in a `list_projects` row and in the embedded `projects[]` of a `list_time_entries` result, `self` is a **bare numeric string** (`"3833165163333022720"`). But inside a **time entry**, `entry.project.self` is the **path form** `"/projects/3833165163333022720"`. Both forms occur in the same payload; the adapter's `strip_projects_prefix/1` (`timing.ex:242-244`) already normalises this. | docs + live `list_projects`, `list_time_entries` |
| **title** | Plain string. Present on every row. | live |
| **parent/child refs** | Docs name a singular `parent` + `children`. **Observed:** `parents` (plural) — an **array** of `{ "self": <bare id>, "title": <string> }` refs — and `children`, same ref shape. Refs carry `title` as well as `self` (docs say children are "provided as references; i.e. they only contain the `self` attribute" — the live connector includes `title` too). Root projects have `parents: []`. | docs + live |
| **archived flag** | `is_archived` — boolean, present on every row. | docs + live |
| **colour** | Docs: `color`, *"hexadecimal format (`#RRGGBB`)"*. **Observed:** 8-hex-digit `#RRGGBBAA` (`"#ECDD47FF"`, `"#47ECADFF"`) and occasionally 6-digit (`"#4DFFB5"`). Treat as an opaque hex colour string, not strictly `#RRGGBB`. | docs + live |
| **other fields present live** | `productivity_score` (int/float −1..1), `notes` (nullable), `team_id` (null for personal), and `default_billing_status` on some rows. | live |
| **`custom_fields`** | Documented; not emitted on the observed rows (none set on this account). | docs |

---

## Q3 — Full ancestor chain per project, or only the immediate parent?

**Only the immediate parent** is reliably available from a `list_projects` call.

- The observed `list_projects` rows carry `parents: [{self, title}]` — **one level up only**.
  No `title_chain`, no grandparent.
- `title_chain` (*"an array containing the title of the project and all its ancestors"*,
  e.g. `["Parent", "Child"]`) **is** documented on the project resource, but was **absent**
  from every observed `list_projects` row **and** absent from a live `show_project` response
  on this connector (which returned only `parents: [{self, title}]`, `children: []`).
  `title_chain` also carries titles only — no ids — so it is not directly usable as a
  hierarchy key even where present.
- **Divergence flag:** the app's `web.timingapp.com/mcp` endpoint may still populate
  `title_chain` (the connector appears to strip it). The adapter should **not depend on
  `title_chain` being present**.

**Consequence for the adapter:** `list_sources/1` must **reconstruct `ancestors` and
`depth` by walking the flat `list_projects` result** — build an `id -> {title, parent_id}`
map from every row's `parents[0].self`, then follow `parent_id` links up to the root for
each project. This needs no extra API calls because `list_projects` already returns every
project in one response. The test account is shallow (root + at most one level:
`SCHS -> {Dev, Meetings}`, `Edu -> Coding`, `Brain Rot -> YouTube - excl educational`),
but the walk should not assume a depth cap. If `parents` ever returns more than one entry,
treat `parents[0]` as the hierarchy parent (Timing projects have a single tree position).

---

## Q4 — Does `list_time_entries`' `projects` filter accept a bare id?

**YES — a bare id works.** Verified live: `list_time_entries` with
`projects: ["3833165163333022720"]` (bare numeric string, no prefix) returned only that
project's entries and nothing else.

- The app already relies on this in production: `fetch_all_entries/5` sets
  `"projects" => projects` straight from each Activity's `time_source_identifier`
  (`timing.ex:151-156`, `timing.ex:64`), and the adapter's tests assert the bare form is
  sent (`timing_test.exs:41-42`: `arguments["projects"] == ["coding-proj-1", ...]`).
- The `/projects/<id>` **path form also works** — Timing's docs examples for the
  `projects[]` filter use `/projects/1`, and `get_activity_hierarchy`'s `project_ids` arg
  is explicitly documented as *"Can include project IDs or `/projects/{id}` format."* The
  filter is lenient and accepts either.
- `strip_projects_prefix/1` exists because the **response** side is inconsistent (entries
  come back with `project.self` = `/projects/<id>` while the picker stores/sends bare ids),
  so the adapter normalises both to bare for bucket-matching — it is **not** evidence that
  the request *requires* the prefix.

**For the map:** the picker can keep storing the **bare source id** in
`time_source_identifier` and pass it directly as a `projects[]` filter value. No prefixing
needed.

Related, if useful for `list_sources` parent roll-ups: `list_time_entries` also accepts
`include_child_projects` (bool, default `0`) — *"the response will also contain time
entries that belong to any child projects of the ones provided in `projects[]`."*

Source: live `mcp__claude_ai_Timing__list_time_entries` call; `web.timingapp.com/docs/`;
`timing.ex`; `timing_test.exs`.

---

## Q5 — Is archived-project exclusion a request argument or a client-side filter?

**A request argument on `list_projects` — and it is the default.** `include_archived`
defaults to `false`, so a plain `list_projects` call **already excludes archived projects
(and their children)** with no client-side filtering required. To get archived projects you
must opt in with `include_archived: true`.

- Timing's REST reference frames the inverse (`hide_archived=1` → *"archived projects and
  their children will not be included"*); the MCP tool exposes it as `include_archived`
  (default false), same effect.
- Note this is a **`list_projects`** capability. `list_time_entries` has **no** archived
  filter argument at all — but that concerns entries, not the project list the picker
  needs, so it does not affect `list_sources/1`.

**For the adapter:** call `list_projects` with no `include_archived` (or explicit `false`)
and every returned project is non-archived. No `is_archived` post-filter needed — though
keeping a defensive `Enum.reject(& &1["is_archived"])` costs nothing.

---

## Summary for the `list_sources/1` adapter implementation

1. **Tool:** `list_projects`, args `include_archived` (bool, default false) and `team_ids`
   (array). Call it with no args.
2. **One call** returns every non-archived project; no pagination.
3. Each row: `self` (**bare id**, but be prefix-tolerant), `title`, `is_archived`,
   `color` (opaque hex), `parents: [{self, title}]`, `children: [{self, title}]`.
4. **No full ancestor chain** — build `ancestors` / `depth` by walking `parents[0].self`
   links across the flat result. Don't rely on `title_chain`.
5. **Archived already excluded** by the default; no client-side archive filter needed.
6. Store & filter with the **bare id** — `list_time_entries`' `projects[]` accepts it
   (verified live).
7. Sort into the map's flat pre-order DFS (parent then subtree, alphabetical by title
   within a level) entirely client-side.

**Open divergence risks — all CLOSED** (see next section).

---

## Direct-endpoint confirmation (`https://web.timingapp.com/mcp`, 2026-09-01)

Probed directly with a `mcp:use`-scoped bearer token over MCP streamable HTTP.
`serverInfo`: `{"name":"Timing MCP Server","version":"0.0.1"}`, protocol `2025-06-18`.

**Tool surface is identical to the claude.ai connector.** `tools/list` returned the same 16
tools; `list_projects`, `show_project`, and `list_time_entries` carry byte-identical input
schemas to those documented above. There is no projects-hierarchy tool. So every finding in
this document transfers to the adapter unchanged.

**`list_projects` (no args) — live response shape:**

- Wrapper object: `{ "projects": [...], "teams": [...] }`.
- Row keys: `self`, `title`, `color`, `productivity_score`, `notes`, `is_archived`,
  `team_id`, `parents`, `children` (plus `default_billing_status` on some rows).
- `self` — **bare numeric string** (`"3817899485969915136"`), no prefix.
- `parents` — **array** of `{self, title}`; **plural**, exactly one element in every nested
  case; `[]` at the root. **No singular `parent`. No `title_chain`** — not on `list_projects`
  rows and not on a `show_project` response for a nested project either.
- `children` — array of `{self, title}`.
- `color` — **`#RRGGBBAA`**, 8-digit uppercase hex with alpha (`"#4DFFEEFF"`, `"#47EC96FF"`,
  `"#ECDD47FF"`). Treat as an opaque string; strip/ignore alpha if a `#RRGGBB` is needed.
- `is_archived` — boolean on every row; archived omitted by default (no `include_archived`).

**`list_time_entries` `projects` filter — bare id confirmed live:**
`{"projects":["3833165163333022720"], "start_date_min":..., "start_date_max":...}` returned
24 matching entries. (`start_date_max` is **required** whenever `start_date_min` is given.)
Returned entries carry `project.self` in **`/projects/<id>`** path form — send bare, receive
prefixed; `strip_projects_prefix/1` bridges the response side. Verdict: **send bare, receive
prefixed.**

**Net effect on the spec:** no change to any adapter conclusion. `list_sources/1` walks
`parents[0].self` across the one-shot `list_projects` result to build `ancestors`/`depth`;
stores and filters on the bare `self`; relies on the `include_archived=false` default; and
carries `color` as an opaque `#RRGGBBAA` string.
