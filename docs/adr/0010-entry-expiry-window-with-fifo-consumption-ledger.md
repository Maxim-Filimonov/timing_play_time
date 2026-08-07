# Entry Expiry Window with FIFO consumption ledger

**Status**: accepted

Reserve was accumulating indefinitely with no decay, which removed the incentive to keep doing Activities once a comfortable buffer built up. We introduced an Entry Expiry Window: each Timing entry's earned minutes stop counting toward the user-facing total once more than 7 days have passed since the entry's own `start_date` (an exact rolling timestamp, re-evaluated on every read — not aligned to local calendar days). This only affects the user-facing figures (Playtime, Today's PT, Reserve); the debug-only Play Balance reveal keeps its original unbounded, all-time total, fetched exactly as before (ADR-0008).

To make expiry behave correctly against spending, we track an Entry Consumption Ledger: each Timing entry has a `remaining` balance, drawn down FIFO whenever Playtime Used is logged — today's own entries are consumed first, then Reserve's entries oldest-first as overflow (preserving the existing "Today's PT resets fresh every local day, no exceptions" rule). Expiry acts on an entry's `remaining` balance, not its original earned amount, so already-spent minutes can never be double-counted against you when their source entry later expires. Everything here is computed live on every read, consistent with this app's existing "recomputed fresh, not stored" pattern (Timing-Derived Earned Total) — no new persisted state, no migration.

As a side effect, every spend now has a traceable Spend Receipt — a per-Activity breakdown of which entries funded it, derived from the ledger's draw-down. This is always shown, even for single-Activity spends, so the UI element is predictable rather than one that intermittently appears.

## Considered options

- **Simple aggregate approximation** (earned = sum of entries within the window; used = untouched all-time total) — rejected once traced through an example: `used_before_today` never ages out while the windowed earned total is capped, so Reserve trends toward increasingly negative over the long run even with steady weekly earning, rather than settling near zero. The FIFO ledger doesn't have this failure mode, since expiry only ever removes minutes already known to be unspent.
- **Per-Activity consumption pools** (you choose which Activity a spend draws from) — rejected in favor of one global pool. Every existing figure (Play Balance, Reserve, Playtime) is already a single number for the whole User, not split by Activity; per-Activity pools would require a new required input at spend-logging time and would let one Activity's balance hit zero while another's is full, which nothing in the current model supports.
- **Pure oldest-first FIFO with no day-scoping** — rejected because it breaks the existing, already-documented Today's PT invariant: a spend could draw entirely from old Reserve stock and leave today's own earnings untouched, making Today's PT appear unaffected by a spend that just happened. Today-first-then-Reserve-overflow preserves that invariant exactly.
- **Activated At as an additional floor on the expiry window** (`max(Activated At, now - 7 days)`) — rejected for simplicity; Activated At is now purely descriptive metadata for the user-facing total and carries no functional weight there. It remains load-bearing for the unchanged, debug-only Timing-Derived Earned Total path.

## Consequences

- ADR-0008's "retroactive earning" quirk (a late-activated Activity retroactively earning for entries before it existed) can no longer happen on the user-facing path, since Activated At no longer bounds it there. ADR-0008 itself is unchanged and still governs the debug-only fetch.
- `CONTEXT.md`'s Reserve entry no longer describes an unbounded, purely-accumulating figure — Reserve now decays from both spending and aging-out, by design.
