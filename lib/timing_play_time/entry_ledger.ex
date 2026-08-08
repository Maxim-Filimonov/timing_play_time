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

  Computed live on every read — no persisted ledger state, consistent with
  this app's "recomputed fresh" pattern.

  **The caller should hand `replay/4` full, unwindowed `entries` history**
  (`PlayBalance.compute_today/4` does this) — pre-filtering entries to the
  Entry Expiry Window before replay was tried and reverted: a usage still
  inside the window can have chronologically drawn on an entry that's
  since aged out (the entry is always at least as old as the usage that
  drew on it, so it can cross the window boundary first), and excluding
  that entry from the pool made the replay re-litigate already-settled
  consumption against whatever's currently visible instead, corrupting
  Reserve. Only `usages` should be pre-filtered to the window — a usage
  older than the window could never have touched an entry still inside it
  (causality), so dropping it is always safe.

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
          required(:start_date) => DateTime.t(),
          required(:play_minutes) => float()
        }

  @type usage :: %{
          required(:id) => term(),
          required(:minutes) => float(),
          required(:logged_at) => DateTime.t()
        }

  @type replayed_entry :: %{
          activity_id: term(),
          start_date: DateTime.t(),
          play_minutes: float(),
          remaining: float()
        }

  @type receipt :: %{usage_id: term(), breakdown: %{optional(term()) => float()}}

  @doc """
  Replays `usages` (any order) against `entries` (any order) in
  chronological order.

  Returns:
    * `:entries` - every given entry, annotated with `:remaining` (its
      `:play_minutes` minus everything drawn from it, floored at 0), sorted
      by `:start_date`
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
        {index, entry |> Map.put(:ledger_id, index) |> Map.put(:remaining, entry.play_minutes)}
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
end
