defmodule TimingPlayTime.EntryLedger do
  @moduledoc """
  The Entry Consumption Ledger (ADR-0010): replays every Playtime Used
  record against individual Timing entries, FIFO, so consumption is tracked
  per-entry rather than as a single running total.

  Each usage is consumed in two passes, in its own local-day terms (not
  relative to "now"): first the entries dated on that usage's own local
  calendar day, then older entries — across every Activity — oldest
  `start_date` first, as overflow. This preserves "Today's PT resets fresh
  every local day" while letting spent-ness travel with the specific entry
  it drew from, so a since-expired entry can never be double-counted
  against a User (see ADR-0010's rejected "simple aggregate" alternative).

  Usages are replayed oldest-first, and a usage can only draw on entries
  that already existed by the time it was logged (`start_date <=
  logged_at`) — consumption never reaches into entries not yet earned.

  Consumption is **persisted**, not recomputed live (ADR-0012) — the one
  deliberate exception to this app's "recomputed fresh" pattern. A live
  replay silently forgot consumption once the spend that caused it aged
  past the Entry Expiry Window, so what each entry has given up is now
  frozen at spend time in the Entry Consumption Ledger. An entry's *total
  earned* is still derived live from its Activity's current Multiplier;
  only the consumed portion is fixed.

  That splits this module in two:

    * **Read path** — `with_remaining/2` (plus `index_consumption/1` and
      `total_consumed/1`) annotates already-fetched entries from persisted
      state. No replay, no usage history. `PlayBalance.compute_today/4`
      uses only these.
    * **Write path** — `replay/4` performs the FIFO draw-down once, at
      spend time, for `PlayBalance.log_spend/6` (a single usage against a
      window-bounded pool whose `:remaining` is pre-loaded from the
      persisted ledger) and for the one-time `mix
      balance.backfill_consumption` (full unwindowed history, replayed
      under the old unbounded rule).

  **`replay/4`'s `entries` and its `window_start` must agree.** Bounding
  the pool to the window is correct only because each entry already
  carries its persisted `:remaining` — the settled past isn't re-litigated
  against whatever's currently visible, it's read back. Replaying *without*
  pre-loaded `:remaining` (the backfill) still needs full, unwindowed
  history for the reason ADR-0010 documented: an entry is always at least
  as old as the usage that drew on it, so it can leave the window first,
  and excluding it would re-spend minutes that are already gone.

  **`load/4` and `fetch/4` are the sanctioned ways to fetch `entries`** —
  nothing should call the `TimeSource` adapter's `list_entries/2` directly.
  Both take the caller's `:from` (every current caller passes
  `PlayBalance.expiry_window_start/1`, ADR-0012: nothing older than the
  window is displayed or spendable any more, so there's no reason to pull
  it). Use `fetch/4` on any path that *writes* — it propagates a fetch
  failure instead of swallowing it to `%{}`, which a write path must never
  mistake for "nothing earned".

  The optional `window_start` tells the reserve-overflow pass which
  entries are still Reserve-visible *right now*, so a fresh spend prefers
  to draw them down first rather than an ancient, already-invisible
  backlog silently absorbing it (entries are still tried oldest-first
  within each of the two priority groups — visible-now, then
  no-longer-visible — so causality and FIFO ordering are preserved within
  each group; only the group boundary is new). Omit it (or pass `nil`) for
  pure oldest-first-across-all-time FIFO, e.g. in tests that don't care
  about windowing.
  """

  alias TimingPlayTime.LocalDay

  @type entry :: %{
          required(:activity_id) => term(),
          required(:time_entry_id) => term(),
          required(:start_date) => DateTime.t(),
          required(:play_minutes) => float(),
          required(:effect) => :positive | :negative,
          optional(:remaining) => float()
        }

  @type usage :: %{
          required(:id) => term(),
          required(:minutes) => float(),
          required(:logged_at) => DateTime.t()
        }

  @type replayed_entry :: %{
          activity_id: term(),
          time_entry_id: term(),
          start_date: DateTime.t(),
          play_minutes: float(),
          effect: :positive | :negative,
          remaining: float()
        }

  @type receipt :: %{usage_id: term(), breakdown: %{optional(term()) => float()}}

  @type consumption_row :: %{
          activity_id: term(),
          time_entry_id: term(),
          consumed_minutes: float()
        }

  @doc """
  Fetches every given Activity's individual time entries via the
  `TimeSource` plug-in contract (ADR-0002), for `build_entries/2`.

  `time_source_opts` is passed straight through to the adapter alongside
  `to: now` — callers bound the fetch to the Entry Expiry Window with
  `from: PlayBalance.expiry_window_start(now)` (ADR-0012).

  A fetch failure returns an empty map rather than propagating the error
  (mirrors `PlayBalance.get_totals/3`'s same swallow), so this is for
  **read paths only** — see `fetch/4` for the strict counterpart every
  write path must use instead.
  """
  @spec load([map()], DateTime.t(), keyword(), (list(), keyword() -> {:ok, map()} | {:error, term()})) ::
          %{optional(String.t()) => [%{start_date: DateTime.t(), minutes: float()}]}
  def load(
        activities,
        now \\ DateTime.utc_now(),
        time_source_opts \\ [],
        list_entries \\ &TimingPlayTime.Plugins.TimeSource.Stub.list_entries/2
      ) do
    case fetch(activities, now, time_source_opts, list_entries) do
      {:ok, entries} -> entries
      {:error, _reason} -> %{}
    end
  end

  @doc """
  `load/4`'s strict counterpart: fetches the same entries but propagates a
  fetch failure as `{:error, reason}` instead of swallowing it to `%{}`.

  Write paths must use this. `PlayBalance.log_spend/5` settles consumption
  durably at spend time (ADR-0012), so an empty pool it can't distinguish
  from a genuine "nothing earned" would book the whole spend as permanent
  `deficit` — and unlike a read, that never self-corrects once the outage
  passes. Read paths can keep using `load/4`, where an empty fetch only
  under-reports until the next successful read.
  """
  @spec fetch([map()], DateTime.t(), keyword(), (list(), keyword() -> {:ok, map()} | {:error, term()})) ::
          {:ok, %{optional(String.t()) => [%{start_date: DateTime.t(), minutes: float()}]}}
          | {:error, term()}
  def fetch(
        activities,
        now \\ DateTime.utc_now(),
        time_source_opts \\ [],
        list_entries \\ &TimingPlayTime.Plugins.TimeSource.Stub.list_entries/2
      ) do
    list_entries.(activities, [to: now] ++ time_source_opts)
  end

  @doc """
  Turns a `load/4`/`fetch/4` result (raw entries keyed by
  `time_source_identifier`) into `entry/0`s: each Activity's Multiplier
  applied, and each entry tagged with the Activity it belongs to, for the
  Entry Consumption Ledger and Spend Receipt.

  `time_entry_id` falls back to `start_date` when a raw entry doesn't carry
  one (e.g. a hand-built test fixture — the real Timing adapter and the Stub
  both always supply one), and is always normalized to a string: the ledger
  persists it in a `:string` column, and Timing's own JSON `id` isn't
  guaranteed to be one. A non-string id both fails to persist and never
  matches the persisted key on the read side (ADR-0012).
  """
  @spec build_entries([map()], %{optional(String.t()) => [map()]}) :: [entry()]
  def build_entries(activities, raw_entries_by_identifier) do
    Enum.flat_map(activities, fn activity ->
      raw_entries_by_identifier
      |> Map.get(activity.time_source_identifier, [])
      |> Enum.map(fn raw_entry ->
        %{
          activity_id: activity.id,
          time_entry_id: to_string(Map.get(raw_entry, :time_entry_id) || raw_entry.start_date),
          start_date: raw_entry.start_date,
          # Unsigned magnitude — `effect` is copied through, no sign applied
          # here (ADR-0013). The sign is only ever taken in `PlayBalance`.
          play_minutes: raw_entry.minutes * activity.multiplier,
          effect: activity.effect
        }
      end)
    end)
  end

  @doc """
  Replays `usages` (any order) against `entries` (any order) in
  chronological order.

  An entry may already carry a `:remaining` (ADR-0012: the persisted
  Entry Consumption Ledger pre-loads it with `play_minutes` minus whatever
  was already durably consumed by earlier, already-persisted spends) — that
  starting value is drawn down instead of being reset to `:play_minutes`.
  An entry with no `:remaining` defaults to fully unspent (`:play_minutes`),
  the original behaviour.

  Returns:
    * `:entries` - every given entry, annotated with `:remaining` (its
      starting `:remaining` — or `:play_minutes`, if none was given — minus
      everything drawn from it this call, floored at 0), sorted by
      `:start_date`
    * `:receipts` - one Spend Receipt per usage, in the same order as the
      given `usages`, each a per-Activity breakdown of how much of that
      usage was funded by that Activity's entries
    * `:deficit` - total minutes across every usage that exceeded every
      entry available (across both passes) at the moment that usage was
      logged — spend with nothing left to draw from, at that point in time
  """
  @spec replay([entry()], [usage()], String.t(), DateTime.t() | nil) :: %{
          entries: [replayed_entry()],
          receipts: [receipt()],
          deficit: float()
        }
  def replay(entries, usages, timezone, window_start \\ nil) do
    # Each entry carries its own map key as :ledger_id, so consume_pool/4 can
    # write a draw-down back to entries_by_id after filtering/sorting a given
    # usage's own copy of the pool into a plain list.
    indexed_entries =
      entries
      |> Enum.sort_by(& &1.start_date, DateTime)
      |> Enum.with_index()
      |> Map.new(fn {entry, index} ->
        {index, entry |> Map.put(:ledger_id, index) |> Map.put_new(:remaining, entry.play_minutes)}
      end)

    sorted_usages = Enum.sort_by(usages, & &1.logged_at, DateTime)

    {final_entries, receipts, deficit} =
      Enum.reduce(
        sorted_usages,
        {indexed_entries, %{}, 0.0},
        &replay_usage(&1, &2, timezone, window_start)
      )

    %{
      entries:
        final_entries
        |> Map.values()
        |> Enum.sort_by(& &1.start_date, DateTime)
        |> Enum.map(&Map.delete(&1, :ledger_id)),
      receipts: Enum.map(usages, &Map.fetch!(receipts, &1.id)),
      deficit: deficit
    }
  end

  defp replay_usage(usage, {entries_by_id, receipts, deficit}, timezone, window_start) do
    day_start = LocalDay.start_of_today(timezone, usage.logged_at)

    exists_by_now? = &(DateTime.compare(&1.start_date, usage.logged_at) != :gt)

    available =
      entries_by_id
      |> Map.values()
      |> Enum.filter(&(&1.remaining > 0 and exists_by_now?.(&1)))
      |> Enum.sort_by(& &1.start_date, DateTime)

    {today_pool, reserve_pool} =
      Enum.split_with(available, &(DateTime.compare(&1.start_date, day_start) != :lt))

    reserve_pool = prioritize_visible(reserve_pool, window_start)

    {entries_by_id, spent_from, remaining_demand} =
      consume_pool(today_pool, usage.minutes, entries_by_id, [])

    {entries_by_id, spent_from, remaining_demand} =
      consume_pool(reserve_pool, remaining_demand, entries_by_id, spent_from)

    receipt = %{usage_id: usage.id, breakdown: aggregate_by_activity(spent_from)}

    {entries_by_id, Map.put(receipts, usage.id, receipt), deficit + remaining_demand}
  end

  # Stable-sorts an already oldest-first `pool` so entries still inside the
  # Entry Expiry Window are drawn from before older, already-invisible
  # backlog — oldest-first is preserved within each of those two groups
  # since Enum.sort_by is a stable sort over an already-sorted input.
  defp prioritize_visible(pool, nil), do: pool

  defp prioritize_visible(pool, window_start) do
    Enum.sort_by(pool, &(DateTime.compare(&1.start_date, window_start) == :lt))
  end

  defp consume_pool(pool, demand, entries_by_id, spent_from) when demand <= 0 or pool == [] do
    {entries_by_id, spent_from, max(demand, 0.0)}
  end

  defp consume_pool([entry | rest], demand, entries_by_id, spent_from) do
    take = min(demand, entry.remaining)
    updated = %{entry | remaining: entry.remaining - take}
    entries_by_id = Map.put(entries_by_id, entry.ledger_id, updated)
    spent_from = [{entry.activity_id, take} | spent_from]

    consume_pool(rest, demand - take, entries_by_id, spent_from)
  end

  defp aggregate_by_activity(spent_from) do
    Enum.reduce(spent_from, %{}, fn {activity_id, minutes}, acc ->
      Map.update(acc, activity_id, minutes, &(&1 + minutes))
    end)
  end

  @doc """
  Indexes persisted `consumption_row/0`s (ADR-0012) by `{activity_id,
  time_entry_id}`, for `with_remaining/2`.
  """
  @spec index_consumption([consumption_row()]) :: %{optional({term(), term()}) => float()}
  def index_consumption(rows) do
    Map.new(rows, &{{&1.activity_id, &1.time_entry_id}, &1.consumed_minutes})
  end

  @doc """
  Annotates each entry with `:remaining` (`:play_minutes` minus whatever
  the indexed consumption (`index_consumption/1`) already recorded against
  it, floored at 0) — the read-side counterpart to `replay/4`'s
  pre-loaded-`:remaining` support (ADR-0012). Unlike `replay/4`, this never
  runs a FIFO draw-down itself; it just looks up already-settled state, so
  reads no longer need to replay usage history to know what's left.
  """
  @spec with_remaining([entry()], %{optional({term(), term()}) => float()}) :: [replayed_entry()]
  def with_remaining(entries, consumption_index) do
    Enum.map(entries, fn entry ->
      consumed = Map.get(consumption_index, {entry.activity_id, entry.time_entry_id}, 0.0)
      Map.put(entry, :remaining, max(entry.play_minutes - consumed, 0.0))
    end)
  end

  @doc """
  Sums `:consumed_minutes` across every given `consumption_row/0`,
  regardless of activity, entry, or window — the all-time total of Play
  Minutes ever actually funded from a Timing entry, used to derive Reserve's
  permanent `deficit` (ADR-0012) without needing entries fetched at all.
  """
  @spec total_consumed([consumption_row()]) :: float()
  def total_consumed(rows) do
    Enum.reduce(rows, 0.0, &(&2 + &1.consumed_minutes))
  end
end
