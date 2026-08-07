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

  **The caller is responsible for windowing `entries` and `usages` to the
  Entry Expiry Window before calling `replay/3`** (`PlayBalance.compute_today/4`
  does this). Reserve-overflow consumption is oldest-`start_date`-first
  with no bound of its own — handed unbounded, all-time history, it drains
  ancient, already-expired-and-invisible entries before ever touching
  anything a User can see, so new spending would appear to do nothing
  until that backlog exhausts. Entries and usages both aging out of the
  window in lockstep (rather than entries alone) is what makes "spend now"
  visibly reduce Reserve immediately, and is also what keeps Reserve from
  drifting ever more negative over time (ADR-0010's rejected "simple
  aggregate" alternative had this failure precisely because *only* earned
  was windowed while *used* stayed all-time).
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
  @spec replay([entry()], [usage()], String.t()) :: %{
          entries: [replayed_entry()],
          receipts: [receipt()],
          deficit: float()
        }
  def replay(entries, usages, timezone) do
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
      Enum.reduce(sorted_usages, {indexed_entries, %{}, 0.0}, &replay_usage(&1, &2, timezone))

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

  defp replay_usage(usage, {entries_by_id, receipts, deficit}, timezone) do
    day_start = LocalDay.start_of_today(timezone, usage.logged_at)

    exists_by_now? = &(DateTime.compare(&1.start_date, usage.logged_at) != :gt)

    available =
      entries_by_id
      |> Map.values()
      |> Enum.filter(&(&1.remaining > 0 and exists_by_now?.(&1)))
      |> Enum.sort_by(& &1.start_date, DateTime)

    {today_pool, reserve_pool} =
      Enum.split_with(available, &(DateTime.compare(&1.start_date, day_start) != :lt))

    {entries_by_id, spent_from, remaining_demand} =
      consume_pool(today_pool, usage.minutes, entries_by_id, [])

    {entries_by_id, spent_from, remaining_demand} =
      consume_pool(reserve_pool, remaining_demand, entries_by_id, spent_from)

    receipt = %{usage_id: usage.id, breakdown: aggregate_by_activity(spent_from)}

    {entries_by_id, Map.put(receipts, usage.id, receipt), deficit + remaining_demand}
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
