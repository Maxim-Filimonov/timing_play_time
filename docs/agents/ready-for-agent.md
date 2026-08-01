# Writing specs an agent can one-shot

Issue #7 ("Batch Timing MCP fetches per dashboard load instead of per-Activity")
went from `ready-for-agent` to a tested, reviewed, committed implementation in
one `/implement` pass, with no clarifying back-and-forth. This is what made
that possible — write future `ready-for-agent` issues the same way.

## What worked

- **Exact contract signatures, not prose descriptions.** The issue gave the
  new `get_elapsed_minutes` callback as an actual typespec (`activities ::
  [Activity.t()]`, the full `opts` shape, the exact return shape), plus which
  option (`:today_from`) is caller-supplied and which (`:from`) is
  adapter-owned. An agent implementing against a typespec doesn't have to
  guess a shape and get it wrong three files downstream.

- **Every design fork pre-resolved in an "Implementation Decisions" section.**
  Where does bucketing happen (adapter, not core)? What happens on partial
  fetch failure (zero everything, not per-Activity isolation)? Does the Stub
  need to batch (no)? Each of these is a real architectural choice — the spec
  made all of them before implementation started, so the agent never had to
  make a judgment call the human hadn't already signed off on.

- **Numbered user stories as acceptance criteria.** Each story named one
  concrete, independently testable behavior (zero Activities → no call;
  pagination past 1000 entries; the no-timezone edge case; the shared-cutoff
  trade-off). Read together they doubled as a test-coverage checklist.

- **A "Testing Decisions" section naming test files, not just "add tests."**
  It said which of the three affected test files gets which new assertions,
  and stated the testing philosophy for this change specifically ("assert on
  external behavior... except where the number/shape of MCP calls is itself
  the behavior under test"). That's the difference between an agent guessing
  what "well tested" means and an agent matching a stated bar.

- **An explicit "Out of Scope" section.** Listed the things a reasonable
  agent might otherwise "fix" while in the neighborhood (per-Activity failure
  isolation, a second adapter, UI changes) and said not to. This is what
  keeps a batching PR from also becoming a refactor PR.

- **Domain docs written *before* the issue, and marked as decided.** The
  ADR (trade-off rationale) and `CONTEXT.md` glossary updates existed before
  the issue was filed, and the issue said outright: "treat as already-decided
  context, not re-litigated during implementation." Settling the *domain*
  question ahead of the *implementation* question meant the agent spent its
  effort on code, not on re-deriving a decision a human already made.

- **External-system facts confirmed and stated inline**, not left for the
  agent to discover or guess: the real API's 1000-entry page cap, descending
  sort order, and the `project.self` (`/projects/<id>`) vs. bare-id
  representation mismatch. Every one of these would have cost a
  trial-and-error round trip (or shipped a silent bug) if the agent had to
  find them by reading API docs or guessing from partial test fixtures.

## Checklist for the next `ready-for-agent` issue

- [ ] Any changed function/callback signature given as an actual type, not a
      paragraph.
- [ ] Every "how should this work" fork resolved under an Implementation
      Decisions heading — nothing left as "use your judgment."
      - [ ] Any accepted trade-off has a named ADR already applied and
            referenced, not "we'll figure out the trade-off later."
- [ ] User stories are concrete enough to become test names.
- [ ] Testing Decisions section names the affected test files and, where the
      change is about call count/shape (batching, caching, an N+1 fix), says
      so explicitly — that's when call-count assertions stop being an
      implementation-detail smell and become the actual behavior under test.
- [ ] Out of Scope section names the adjacent things NOT to touch.
- [ ] Any external-API quirks relevant to the change (rate limits, page
      caps, ID formats, ordering guarantees) are confirmed and stated inline,
      not left implicit.
- [ ] If the spec involves a new adapter or a new per-entity call to an
      external system, checked for an N+1 shape (one call per domain entity)
      before the contract's signature is finalized — see
      [ADR-0009](../adr/0009-batch-per-entity-adapter-calls-to-avoid-n-plus-1.md).
