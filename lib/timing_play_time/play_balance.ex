defmodule TimingPlayTime.PlayBalance do
  @moduledoc """
  Calculates a User's current Play Balance (ADR-0006).

  Play Balance = Timing-Derived Earned Total + Manual Sync - Playtime Used Total

  Where:
  - Timing-Derived Earned Total: Sum of (elapsed minutes × multiplier) for all active Activities
  - Manual Sync: Absolute total from external source (e.g., exercise app)
  - Playtime Used Total: Sum of all logged playtime usage
  """

  alias TimingPlayTime.EntryLedger
  alias TimingPlayTime.LocalDay
  alias TimingPlayTime.PlaytimeUsed

  @persistence Application.compile_env!(:timing_play_time, :persistence_adapter)
  @time_source Application.compile_env!(:timing_play_time, :time_source_adapter)

  # The Entry Expiry Window (ADR-0010): an exact rolling cutoff, re-evaluated
  # on every read, not aligned to local calendar days.
  @expiry_window_days 7

  @doc """
  The Entry Expiry Window's start (ADR-0010): an exact rolling cutoff
  `now - 7 days`, not aligned to local calendar days. Exposed so callers
  fetching `list_entries/2` results themselves (e.g. the dashboard,
  prefetching once for both `compute_today/4` and a per-Activity "This
  Week" figure) can bound that fetch to the same window `compute_today/4`
  uses internally, rather than fetching unbounded history and relying on
  this module to filter it back down to size.

  ## Examples

      iex> PlayBalance.expiry_window_start(~U[2026-07-25 10:00:00Z])
      ~U[2026-07-18 10:00:00Z]
  """
  def expiry_window_start(now \\ DateTime.utc_now()) do
    DateTime.add(now, -@expiry_window_days, :day)
  end

  @doc """
  Computes the current Play Balance for a user.

  `time_source_opts` is merged into every `get_elapsed_minutes/2` call — used
  to pass the per-mount `client:` connection opened by the dashboard LiveView
  (ADR-0007), rather than a global singleton.

  Returns a map with:
  - `:total` - The net balance (can be negative)
  - `:timing_derived_total` - Sum from Activities
  - `:manual_sync_total` - Manual sync value
  - `:playtime_used_total` - Total spent

  ## Examples

      iex> PlayBalance.compute(user)
      {:ok, %{
        total: 142.0,
        timing_derived_total: 187.0,
        manual_sync_total: 0.0,
        playtime_used_total: 45.0
      }}
  """
  def compute(
        user,
        time_source_opts \\ [],
        get_elapsed_minutes \\ &@time_source.get_elapsed_minutes/2
      ) do
    with {:ok, activities} <- @persistence.list_activities(user.id),
         {:ok, manual_sync} <- get_manual_sync_total(user),
         {:ok, playtime_used} <- get_playtime_used_total(user) do
      timing_derived =
        compute_timing_derived_total(activities, time_source_opts, get_elapsed_minutes)

      balance = %{
        timing_derived_total: timing_derived,
        manual_sync_total: manual_sync,
        playtime_used_total: playtime_used,
        total: timing_derived + manual_sync - playtime_used
      }

      {:ok, balance}
    end
  end

  @doc """
  Computes an Activity's raw Timing minutes and Play Minutes for just today
  (the user's local calendar day, per `user.timezone` / ADR-0006), for the
  dashboard's per-Activity breakdown.

  Entries are counted from local start-of-today onward regardless of when
  the Activity was activated — an Activity activated earlier is clamped to
  just today, and one activated later today still counts entries logged
  earlier that same local day, since local start-of-today never falls after
  the local day containing its own Activated At.

  ## Examples

      iex> PlayBalance.today_activity_minutes(activity, user)
      {:ok, %{minutes: 27.5, play_minutes: 41.25}}
  """
  def today_activity_minutes(
        activity,
        user,
        now \\ DateTime.utc_now(),
        get_elapsed_minutes \\ &@time_source.get_elapsed_minutes/2
      ) do
    today_from = LocalDay.start_of_today(user.timezone, now)

    with {:ok, totals} <- get_elapsed_minutes.([activity], to: now, today_from: today_from) do
      minutes = minutes_for(totals, activity, :today)
      {:ok, %{minutes: minutes, play_minutes: minutes * activity.multiplier}}
    end
  end

  @doc """
  Computes an Activity's raw Timing minutes and Play Minutes for the last 7
  days (the Entry Expiry Window's exact rolling cutoff, `now - 7 days` —
  ADR-0010, not aligned to local calendar days like `today_activity_minutes/4`
  is), for the dashboard's per-Activity "This Week" figure.

  Unlike `today_activity_minutes/4` (which uses `get_elapsed_minutes/2`'s
  pre-aggregated cumulative/today totals), this uses `list_entries/2`'s
  individual dated entries, since an arbitrary 7-day window needs entry
  dates to filter by, not a pre-aggregated sum. This is the raw earned
  total, not net of any spending — Playtime Used draws from a single global
  pool, not a per-Activity one (see CONTEXT.md's Playtime Used entry), so
  there's no meaningful way to net a spend against one Activity's figure
  alone the way `PlayBalance.compute_today/4`'s ledger nets the User's
  total.

  ## Examples

      iex> PlayBalance.week_activity_minutes(activity)
      {:ok, %{minutes: 120.0, play_minutes: 180.0}}
  """
  def week_activity_minutes(
        activity,
        now \\ DateTime.utc_now(),
        list_entries \\ &@time_source.list_entries/2
      ) do
    window_start = expiry_window_start(now)

    with {:ok, entries_by_identifier} <- list_entries.([activity], from: window_start, to: now) do
      minutes =
        entries_by_identifier
        |> Map.get(activity.time_source_identifier, [])
        |> Enum.filter(&(DateTime.compare(&1.start_date, window_start) != :lt))
        |> Enum.reduce(0.0, &(&2 + &1.minutes))

      {:ok, %{minutes: minutes, play_minutes: minutes * activity.multiplier}}
    end
  end

  @doc """
  Computes the dashboard's "Playtime" figure: Today's PT (today's earned
  Play Minutes, net of the Entry Consumption Ledger's draw-down — resets
  every local calendar day, no exceptions) plus Reserve (User Displayed
  Total's prior-days portion, plus the Pushscroll Balance).

  `today_net` and `reserve` are ledger-based (ADR-0010), not simple
  subtraction: every Playtime Used record *within the Entry Expiry Window*
  is replayed, oldest first, against individual Timing entries *also
  within the window* — each usage consumes its own local day's entries
  first, then older entries (oldest `start_date` first) as overflow. Both
  sides of the ledger are windowed together, not just the earned side —
  handing `TimingPlayTime.EntryLedger` unbounded all-time history instead
  would let its oldest-first draw-down silently drain ancient,
  already-expired entries no User can see before ever reaching Reserve, so
  new spending would appear to do nothing until that backlog exhausts.
  Because consumption is tracked per-entry, an entry aging out of the
  window (more than 7 days since its own `start_date`) takes any
  already-recorded spend against it with it — unlike a raw running "used"
  total, this can never re-count as debt against a User once the entries it
  drew from are gone (see ADR-0010's rejected "simple aggregate"
  alternative). A usage older than the window is excluded from the replay
  entirely rather than just from display, for the same reason: causality
  means it could never have touched anything still in-window anyway.

  `today_net` is always >= 0 (today's entries fully fund a spend before
  overflowing elsewhere, so there's nothing left on them to go negative).
  `reserve` absorbs every overflow instead — including "spend that exceeded
  every entry earned so far, at the moment it was logged" (the ledger's
  `:deficit`) — which is the only way Reserve goes negative other than a
  negative Pushscroll Balance; it never goes negative purely from expiry,
  since expiry only ever removes minutes already known to be unspent.
  `playtime` (`today_net + reserve`) is unaffected by exactly how the
  overflow is attributed between the two — it's a pure decomposition of the
  same total either way.

  Pushscroll Balance has no day boundary or per-entry ledger of its own —
  it's a net balance synced from an external app — so it's folded into
  Reserve rather than Today's PT, alongside the rest of the carried-over
  history.

  `earned_today` and `used_today` are the raw (non-ledger) day totals shown
  alongside `today_net`, for display — how much was earned/spent today,
  independent of what a spend was actually matched against. `week_earned`
  and `week_used` are the same idea over the full window: every in-window
  entry's original (pre-consumption) `play_minutes`, and every recent
  usage's `minutes`, both summed with no ledger involved.

  **`playtime == week_earned - week_used + pushscroll_balance`, exactly,
  always** — the ledger's `:deficit` is *by construction* the part of
  `week_used` that didn't come out of any entry's `remaining`
  (`consumed_from_entries + deficit == week_used`), so it cancels out of
  this identity algebraically even though it's very much present inside
  `today_net`/`reserve`'s own math. This is what makes `week_earned`/
  `week_used` worth showing on their own next to `playtime` — unlike
  `today_net + reserve`, this decomposition needs no explanation of
  flooring, causality, or where deficit went to visibly check the
  arithmetic.

  ## Examples

      iex> PlayBalance.compute_today(user)
      {:ok, %{
        earned_today: 27.5,
        used_today: 10.0,
        week_earned: 120.0,
        week_used: 90.0,
        pushscroll_balance: 15.0,
        today_net: 17.5,
        reserve: 42.0,
        playtime: 59.5,
        receipts: [%{usage_id: "...", breakdown: %{"activity-id" => 10.0}}]
      }}
  """
  def compute_today(
        user,
        now \\ DateTime.utc_now(),
        time_source_opts \\ [],
        list_entries \\ &@time_source.list_entries/2
      ) do
    today_from = LocalDay.start_of_today(user.timezone, now)
    window_start = expiry_window_start(now)

    with {:ok, activities} <- @persistence.list_activities(user.id),
         {:ok, pushscroll_balance} <- get_manual_sync_total(user),
         {:ok, usages} <- PlaytimeUsed.list_all(user.id),
         {:ok, used_today} <- PlaytimeUsed.total_used_today(user.id, user.timezone, now) do
      opts = [from: window_start, to: now] ++ time_source_opts
      raw_entries = fetch_entries(activities, opts, list_entries)

      # Filtered again here, not just requested via `opts[:from]` above — an
      # adapter that doesn't fully honor `:from` (or returns a superset)
      # must not be able to hand the ledger anything outside the window;
      # see the comment on `recent_usages` below for why that matters.
      ledger_entries =
        activities
        |> build_ledger_entries(raw_entries)
        |> Enum.filter(&(DateTime.compare(&1.start_date, window_start) != :lt))

      earned_today =
        sum_ledger_entries(ledger_entries, &(DateTime.compare(&1.start_date, today_from) != :lt))

      # Usages older than the window are excluded, not just entries — a
      # usage can only ever have consumed an entry that already existed
      # (causality), so one more than 7 days old could never have touched
      # anything still in-window anyway. Handing the ledger unbounded
      # all-time history instead would let its oldest-first reserve
      # draw-down drain ancient, already-invisible entries before ever
      # reaching anything a User can see — new spending would then appear
      # to do nothing until that backlog exhausts (see EntryLedger's
      # moduledoc).
      recent_usages = Enum.filter(usages, &(DateTime.compare(&1.logged_at, window_start) != :lt))

      %{entries: replayed, receipts: receipts, deficit: deficit} =
        EntryLedger.replay(ledger_entries, recent_usages, user.timezone)

      in_window = Enum.filter(replayed, &(DateTime.compare(&1.start_date, window_start) != :lt))

      {today_entries, reserve_entries} =
        Enum.split_with(in_window, &(DateTime.compare(&1.start_date, today_from) != :lt))

      today_net = sum_remaining(today_entries)
      reserve = sum_remaining(reserve_entries) + pushscroll_balance - deficit

      week_earned = Enum.reduce(ledger_entries, 0.0, &(&2 + &1.play_minutes))
      week_used = Enum.reduce(recent_usages, 0.0, &(&2 + &1.minutes))

      {:ok,
       %{
         earned_today: earned_today,
         used_today: used_today,
         week_earned: week_earned,
         week_used: week_used,
         pushscroll_balance: pushscroll_balance,
         today_net: today_net,
         reserve: reserve,
         playtime: today_net + reserve,
         receipts: receipts
       }}
    end
  end

  # Private functions

  defp compute_timing_derived_total(activities, time_source_opts, get_elapsed_minutes) do
    totals = fetch_totals(activities, time_source_opts, get_elapsed_minutes)
    sum_totals(activities, totals, :cumulative)
  end

  # A single Timing fetch failure zeroes every Activity's totals for this
  # computation (ADR-0008's accepted shared failure blast radius) rather
  # than isolating the failure to just one Activity.
  defp fetch_totals(activities, time_source_opts, get_elapsed_minutes) do
    case get_elapsed_minutes.(activities, time_source_opts) do
      {:ok, totals} -> totals
      {:error, _reason} -> %{}
    end
  end

  defp sum_totals(activities, totals, key) do
    Enum.reduce(activities, 0.0, fn activity, acc ->
      acc + minutes_for(totals, activity, key) * activity.multiplier
    end)
  end

  defp minutes_for(totals, activity, key) do
    case Map.fetch(totals, activity.time_source_identifier) do
      {:ok, %{^key => minutes}} when is_number(minutes) -> minutes
      _ -> 0.0
    end
  end

  defp get_manual_sync_total(user) do
    @persistence.get_manual_sync_total(user.id)
  end

  defp get_playtime_used_total(user) do
    @persistence.total_playtime_used(user.id)
  end

  # A fetch failure zeroes every Activity's entries for this computation
  # (mirrors fetch_totals/3's ADR-0008 shared failure blast radius).
  defp fetch_entries(activities, opts, list_entries) do
    case list_entries.(activities, opts) do
      {:ok, entries} -> entries
      {:error, _reason} -> %{}
    end
  end

  # Applies each Activity's Multiplier to its raw Timing entries, tagging
  # each with the Activity it belongs to for the Entry Consumption Ledger
  # and Spend Receipt.
  defp build_ledger_entries(activities, raw_entries_by_identifier) do
    Enum.flat_map(activities, fn activity ->
      raw_entries_by_identifier
      |> Map.get(activity.time_source_identifier, [])
      |> Enum.map(fn %{start_date: start_date, minutes: minutes} ->
        %{
          activity_id: activity.id,
          start_date: start_date,
          play_minutes: minutes * activity.multiplier
        }
      end)
    end)
  end

  defp sum_ledger_entries(entries, filter) do
    entries |> Enum.filter(filter) |> Enum.reduce(0.0, &(&2 + &1.play_minutes))
  end

  defp sum_remaining(entries) do
    Enum.reduce(entries, 0.0, &(&2 + &1.remaining))
  end
end
