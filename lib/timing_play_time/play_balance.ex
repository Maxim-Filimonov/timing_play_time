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
  alias TimingPlayTime.PlayBalance.Today
  alias TimingPlayTime.PlaytimeUsed

  @persistence Application.compile_env!(:timing_play_time, :persistence_adapter)
  @time_source Application.compile_env!(:timing_play_time, :time_source_adapter)

  # The Entry Expiry Window (ADR-0010): an exact rolling cutoff, re-evaluated
  # on every read, not aligned to local calendar days.
  @expiry_window_days 7

  @doc """
  The Entry Expiry Window's start (ADR-0010): an exact rolling cutoff
  `now - 7 days`, not aligned to local calendar days. Exposed for display
  (e.g. `Mix.Tasks.Balance.Snapshot` prints it) — `compute_today/4` and
  `week_activity_minutes/4` both use it internally to filter their
  already-loaded entries down to the window, and as of ADR-0012 it also
  bounds the fetch itself (`from:`), since nothing older than the window is
  displayed or spendable any more.

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
  def compute(user, time_source_opts \\ [], totals \\ nil) do
    with {:ok, activities} <- @persistence.list_activities(user.id),
         {:ok, manual_sync} <- get_manual_sync_total(user),
         {:ok, playtime_used} <- get_playtime_used_total(user) do
      totals = totals || get_totals(activities, time_source_opts)
      timing_derived = sum_totals(activities, totals, :cumulative)

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
      {:ok, activity_today_minutes(totals, activity)}
    end
  end

  @doc """
  Pulls one Activity's `:today` figure out of an already-fetched `totals`
  map (the shape `get_totals/3`/`get_elapsed_minutes/2` return) and applies
  its Multiplier — no fetch of its own, so a caller sharing one fetch
  across several Activities (e.g. `DashboardLive`) can call this directly
  instead of going through `today_activity_minutes/4`'s own fetch.
  """
  def activity_today_minutes(totals, activity) do
    minutes = minutes_for(totals, activity, :today)
    %{minutes: minutes, play_minutes: minutes * activity.multiplier}
  end

  @doc """
  Computes an Activity's raw Timing minutes and Play Minutes for the last 7
  days (the Entry Expiry Window's exact rolling cutoff, `now - 7 days` —
  ADR-0010, not aligned to local calendar days like `today_activity_minutes/4`
  is), for the dashboard's per-Activity "This Week" figure.

  Unlike `today_activity_minutes/4` (which uses `get_elapsed_minutes/2`'s
  pre-aggregated cumulative/today totals), this uses individual dated
  entries (`EntryLedger.load/4`), since an arbitrary 7-day window needs
  entry dates to filter by, not a pre-aggregated sum. This is the raw
  earned total, not net of any spending — Playtime Used draws from a
  single global pool, not a per-Activity one (see CONTEXT.md's Playtime
  Used entry), so there's no meaningful way to net a spend against one
  Activity's figure alone the way `PlayBalance.compute_today/4`'s ledger
  nets the User's total.

  `raw_entries` — when given (e.g. by `DashboardLive`, sharing one fetch
  across every Activity and `compute_today/4`, already bounded to the
  window) — is `EntryLedger.load/4`'s return shape, keyed by
  `time_source_identifier`. When omitted, this fetches it itself via
  `EntryLedger.load/4` with no `from:` of its own — filtering down to the
  window happens here either way, so the wider input doesn't change the
  result, only how much is fetched.

  ## Examples

      iex> PlayBalance.week_activity_minutes(activity)
      {:ok, %{minutes: 120.0, play_minutes: 180.0}}
  """
  def week_activity_minutes(
        activity,
        now \\ DateTime.utc_now(),
        time_source_opts \\ [],
        raw_entries \\ nil
      ) do
    window_start = expiry_window_start(now)
    raw_entries = raw_entries || EntryLedger.load([activity], now, time_source_opts)

    minutes =
      raw_entries
      |> Map.get(activity.time_source_identifier, [])
      |> Enum.filter(&(DateTime.compare(&1.start_date, window_start) != :lt))
      |> Enum.reduce(0.0, &(&2 + &1.minutes))

    {:ok, %{minutes: minutes, play_minutes: minutes * activity.multiplier}}
  end

  @doc """
  Computes the dashboard's "Playtime" figure: Today's PT (today's earned
  Play Minutes, net of the Entry Consumption Ledger's draw-down — resets
  every local calendar day, no exceptions) plus Reserve (User Displayed
  Total's prior-days portion, plus the Pushscroll Balance).

  As of ADR-0012, this is a pure read: every entry's `remaining` comes
  straight from the persisted Entry Consumption Ledger
  (`EntryLedger.with_remaining/2`, joining live-fetched entries against
  `@persistence.list_entry_consumption/1`) rather than replaying usage
  history live. All the drawing-down happens once, at write time, in
  `log_spend/6` — this function never mutates anything.

  `reserve`'s `deficit` term is derived, not replayed: the all-time gap
  between everything ever logged (`PlaytimeUsed.total_used/1`) and
  everything ever actually funded from an entry
  (`EntryLedger.total_consumed/1`, summed from the same persisted rows).
  This is permanent and window-independent by construction — an old
  entry aging out doesn't touch it, since expiry only removes *unspent*
  `remaining`, never rewrites what was already recorded as consumed.

  `today_net` is always >= 0 (a spend draws today's own entries before
  ever overflowing into reserve, at write time — see `log_spend/6`).
  `reserve` absorbs every overflow instead, including `deficit`, which is
  the only way it goes negative other than a negative Pushscroll Balance.
  `playtime` (`today_net + reserve`) is unaffected by exactly how the
  overflow is attributed between the two.

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

  See `TimingPlayTime.PlayBalance.Today` for the full field-by-field
  breakdown, including the `playtime == week_earned - week_used +
  pushscroll_balance` reconciliation identity.

  `raw_entries` — when given (e.g. by `DashboardLive`, sharing one fetch
  across `week_activity_minutes/4` too) — is `EntryLedger.load/4`'s return
  shape, keyed by `time_source_identifier`. As of ADR-0012 it only needs to
  cover the Entry Expiry Window (`expiry_window_start/1` onward) — nothing
  older than that is ever displayed or spendable any more, unlike the
  unbounded fetch ADR-0010 required for backlog. When omitted, this fetches
  it itself via `EntryLedger.load/4`, bounded the same way.

  ## Examples

      iex> PlayBalance.compute_today(user)
      {:ok, %TimingPlayTime.PlayBalance.Today{
        earned_today: 27.5,
        used_today: 10.0,
        week_earned: 120.0,
        week_used: 90.0,
        pushscroll_balance: 15.0,
        today_net: 17.5,
        reserve: 42.0,
        playtime: 59.5
      }}
  """
  def compute_today(
        user,
        now \\ DateTime.utc_now(),
        time_source_opts \\ [],
        raw_entries \\ nil
      ) do
    today_from = LocalDay.start_of_today(user.timezone, now)
    window_start = expiry_window_start(now)

    with {:ok, activities} <- @persistence.list_activities(user.id),
         {:ok, pushscroll_balance} <- get_manual_sync_total(user),
         {:ok, used_today} <- PlaytimeUsed.total_used_today(user.id, user.timezone, now),
         {:ok, total_used} <- PlaytimeUsed.total_used(user.id),
         {:ok, usages} <- PlaytimeUsed.list_all(user.id),
         {:ok, consumption} <- @persistence.list_entry_consumption(user.id) do
      raw_entries =
        raw_entries || EntryLedger.load(activities, now, [from: window_start] ++ time_source_opts)

      week_entries =
        activities
        |> EntryLedger.build_entries(raw_entries)
        |> Enum.filter(&(DateTime.compare(&1.start_date, window_start) != :lt))
        |> EntryLedger.with_remaining(EntryLedger.index_consumption(consumption))

      {today_entries, reserve_entries} =
        Enum.split_with(week_entries, &(DateTime.compare(&1.start_date, today_from) != :lt))

      today_net = sum_remaining(today_entries)
      deficit = max(total_used - EntryLedger.total_consumed(consumption), 0.0)
      reserve = sum_remaining(reserve_entries) + pushscroll_balance - deficit

      earned_today = sum_play_minutes(today_entries)
      week_earned = sum_play_minutes(week_entries)

      week_used =
        usages
        |> Enum.filter(&(DateTime.compare(&1.logged_at, window_start) != :lt))
        |> Enum.reduce(0.0, &(&2 + &1.minutes))

      {:ok,
       %Today{
         earned_today: earned_today,
         used_today: used_today,
         week_earned: week_earned,
         week_used: week_used,
         pushscroll_balance: pushscroll_balance,
         today_net: today_net,
         reserve: reserve,
         playtime: today_net + reserve
       }}
    end
  end

  @doc """
  Logs a Playtime Used spend and durably persists exactly what it drew
  from (ADR-0012) — the single write path for spending. Unlike
  `compute_today/4` (a pure read), this performs the FIFO draw-down once,
  now, and writes the result to the Entry Consumption Ledger and the usage
  record together as one atomic write, `@persistence.record_spend/4` — a
  mid-write failure can never leave entries marked as consumed with no
  matching usage, or vice versa.

  The pool a spend can draw from is deliberately bounded to today's own
  entries plus Reserve's entries still inside the Entry Expiry Window —
  never Backlog (entries already outside the window at the moment of
  logging). Once that bounded pool runs dry, the remainder registers as
  `deficit` rather than reaching further back, same as `compute_today/4`'s
  `reserve` already accounts for. An already-persisted entry keeps
  whatever it's already given up even after it later ages out of the
  window — expiry only removes what's still `remaining`.

  `raw_entries`, when given, must already be bounded to the window (same
  shape as `compute_today/4`'s) — when omitted, this fetches it itself via
  `EntryLedger.fetch/4`, the strict variant: a spend must never be settled
  against entries a failed fetch turned into an empty pool, since the
  resulting `deficit` is permanent and (unlike a read) never self-corrects.

  ## Returns
    * `{:ok, %{usage: usage, receipt: receipt, deficit: deficit}}`
    * `{:error, :no_timezone}` - if the User has no timezone yet; the
      day-scoped first pass has no boundary to work from (ADR-0005), so
      nothing is written and the spend can be retried once one is set
    * `{:error, reason}` - if activities, existing consumption, or the
      entries fetch fail, or the write itself does; nothing is left
      partially applied either way
  """
  def log_spend(
        user,
        minutes,
        now \\ DateTime.utc_now(),
        time_source_opts \\ [],
        raw_entries \\ nil,
        list_entries \\ &@time_source.list_entries/2
      )

  # The two-pass draw-down needs a local day boundary (ADR-0005), and a User
  # whose timezone hasn't been detected yet has none. Refuse the spend rather
  # than crashing or guessing a boundary — nothing is written, so the User can
  # retry once they've set a timezone in Settings.
  def log_spend(%{timezone: nil}, _minutes, _now, _time_source_opts, _raw_entries, _list_entries) do
    {:error, :no_timezone}
  end

  def log_spend(user, minutes, now, time_source_opts, raw_entries, list_entries) do
    window_start = expiry_window_start(now)

    with {:ok, activities} <- @persistence.list_activities(user.id),
         {:ok, consumption} <- @persistence.list_entry_consumption(user.id),
         {:ok, raw_entries} <-
           fetch_spend_entries(raw_entries, activities, now, window_start, time_source_opts, list_entries) do
      pool =
        activities
        |> EntryLedger.build_entries(raw_entries)
        |> Enum.filter(&(DateTime.compare(&1.start_date, window_start) != :lt))
        |> EntryLedger.with_remaining(EntryLedger.index_consumption(consumption))

      usage = %{id: :pending, minutes: minutes, logged_at: now}

      %{entries: drawn, receipts: [receipt], deficit: deficit} =
        EntryLedger.replay(pool, [usage], user.timezone, nil)

      consumptions = draw_down_deltas(pool, drawn)

      with {:ok, logged_usage} <- @persistence.record_spend(user.id, consumptions, minutes, now) do
        {:ok, %{usage: logged_usage, receipt: %{receipt | usage_id: logged_usage.id}, deficit: deficit}}
      end
    end
  end

  @doc """
  Fetches every given Activity's cumulative and today-scoped elapsed
  minutes in one call (ADR-0008), via the `TimeSource` plug-in contract
  (ADR-0002). A single fetch failure zeroes every Activity's totals for
  the computation (ADR-0008's accepted shared failure blast radius)
  rather than isolating the failure to just one Activity.
  """
  def get_totals(activities, opts \\ [], get_elapsed_minutes \\ &@time_source.get_elapsed_minutes/2) do
    case get_elapsed_minutes.(activities, opts) do
      {:ok, totals} -> totals
      {:error, _reason} -> %{}
    end
  end

  # Private functions

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

  # A spend is a durable write (ADR-0012), so its entries fetch must be the
  # strict `EntryLedger.fetch/4`, not the swallowing `load/4`: an outage that
  # read as an empty pool would book the whole spend as `deficit`, and
  # `deficit` (total_used - total_consumed) never self-corrects the way a
  # failed read does. An already-fetched `raw_entries` is taken as-is — its
  # own caller already handled the failure.
  defp fetch_spend_entries(nil, activities, now, window_start, time_source_opts, list_entries) do
    EntryLedger.fetch(activities, now, [from: window_start] ++ time_source_opts, list_entries)
  end

  defp fetch_spend_entries(raw_entries, _activities, _now, _window_start, _opts, _list_entries) do
    {:ok, raw_entries}
  end

  defp sum_play_minutes(entries) do
    Enum.reduce(entries, 0.0, &(&2 + &1.play_minutes))
  end

  defp sum_remaining(entries) do
    Enum.reduce(entries, 0.0, &(&2 + &1.remaining))
  end

  # Diffs `drawn` (post-replay) against `pool` (pre-replay) by
  # {activity_id, time_entry_id}, keeping only what actually moved — an
  # entry untouched by this spend contributes nothing, keeping the sparse
  # Entry Consumption Ledger sparse (ADR-0012). The result feeds
  # `@persistence.record_spend/4` as one atomic write, rather than each
  # delta being persisted as its own separate call.
  defp draw_down_deltas(pool, drawn) do
    starting_remaining = Map.new(pool, &{{&1.activity_id, &1.time_entry_id}, &1.remaining})

    drawn
    |> Enum.map(fn entry ->
      key = {entry.activity_id, entry.time_entry_id}
      delta = Map.fetch!(starting_remaining, key) - entry.remaining
      %{activity_id: entry.activity_id, time_entry_id: entry.time_entry_id, minutes: delta}
    end)
    |> Enum.filter(&(&1.minutes > 0))
  end
end
