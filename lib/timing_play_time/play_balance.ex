defmodule TimingPlayTime.PlayBalance do
  @moduledoc """
  Calculates a User's current Play Balance (ADR-0006).

  Play Balance = Timing-Derived Earned Total + Manual Sync - Playtime Used Total

  Where:
  - Timing-Derived Earned Total: Sum of (elapsed minutes × multiplier) for all active Activities
  - Manual Sync: Absolute total from external source (e.g., exercise app)
  - Playtime Used Total: Sum of all logged playtime usage
  """

  alias TimingPlayTime.LocalDay
  alias TimingPlayTime.PlaytimeUsed

  @persistence Application.compile_env!(:timing_play_time, :persistence_adapter)
  @time_source Application.compile_env!(:timing_play_time, :time_source_adapter)

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
  Computes the dashboard's "Playtime" figure: Today's PT (today's
  Timing-earned Play Minutes, minus today's Playtime Used — resets every
  local calendar day, no exceptions) plus Reserve (Play Minutes earned but
  not yet spent from days *before* today, plus the Pushscroll Balance).

  Pushscroll Balance has no day boundary of its own — it's a net balance
  synced from an external app (rises when the User exercises, falls when
  they spend it on Pushscroll-tracked apps) — so it's folded into Reserve
  rather than Today's PT, alongside the rest of the carried-over history.

  `reserve` is derived as (cumulative Timing-Derived Earned Total minus
  today's earned) minus prior-days' Playtime Used, plus Pushscroll Balance —
  a pure decomposition, so `playtime` always equals what `compute/2` would
  return as `:total` for the same activity, just split into a today part and
  a carried-over part.

  Unlike `compute/2`, `earned_today`/`today_net` reset to just today's
  activity every local calendar day; `reserve` is where the rest of the
  history (and the synced Pushscroll Balance) lives instead of
  disappearing. Every field can go negative (no clamping) — a User can log
  more Playtime Used than they've earned, either today or historically.

  ## Examples

      iex> PlayBalance.compute_today(user)
      {:ok, %{
        earned_today: 27.5,
        used_today: 10.0,
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
        get_elapsed_minutes \\ &@time_source.get_elapsed_minutes/2
      ) do
    today_from = LocalDay.start_of_today(user.timezone, now)

    with {:ok, activities} <- @persistence.list_activities(user.id),
         {:ok, pushscroll_balance} <- get_manual_sync_total(user),
         {:ok, used_today} <- PlaytimeUsed.total_used_today(user.id, user.timezone, now),
         {:ok, used_before_today} <-
           PlaytimeUsed.total_used_before_today(user.id, user.timezone, now) do
      opts = [to: now, today_from: today_from] ++ time_source_opts
      totals = fetch_totals(activities, opts, get_elapsed_minutes)

      earned_today = sum_totals(activities, totals, :today)
      earned_cumulative = sum_totals(activities, totals, :cumulative)

      today_net = earned_today - used_today
      reserve = earned_cumulative - earned_today - used_before_today + pushscroll_balance

      {:ok,
       %{
         earned_today: earned_today,
         used_today: used_today,
         pushscroll_balance: pushscroll_balance,
         today_net: today_net,
         reserve: reserve,
         playtime: today_net + reserve
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
end
