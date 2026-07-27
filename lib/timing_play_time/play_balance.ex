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
  def compute(user, time_source_opts \\ []) do
    with {:ok, timing_derived} <- compute_timing_derived_total(user, time_source_opts),
         {:ok, manual_sync} <- get_manual_sync_total(user),
         {:ok, playtime_used} <- get_playtime_used_total(user) do
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

  `from` is the later of local start-of-today and the local start-of-day
  containing the Activity's Activated At — so an Activity activated later
  today still counts entries logged earlier that same local day (matching
  the Timing-Derived Earned Total's day-boundary parity), while an Activity
  activated on an earlier day is clamped to just today.

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
    from =
      later(
        LocalDay.start_of_today(user.timezone, activity.activated_at),
        LocalDay.start_of_today(user.timezone, now)
      )

    with {:ok, minutes} <- get_elapsed_minutes.(activity, from: from, to: now) do
      {:ok, %{minutes: minutes, play_minutes: minutes * activity.multiplier}}
    end
  end

  defp later(a, b) do
    if DateTime.compare(a, b) == :gt, do: a, else: b
  end

  @doc """
  Computes the dashboard's day-scoped "Playtime" figure: today's Timing-earned
  Play Minutes plus today's Playtime Used, minus all-time Exercise Minutes
  (Manual Sync, which can't be day-scoped — see `TimingPlayTime.PlaytimeUsed.total_used_today/3`).

  Unlike `compute/2`, this does not accumulate indefinitely — it resets to
  just today's activity every local calendar day, and every field can be
  negative (no clamping): a User can log more Playtime Used today than
  they've earned today.

  ## Examples

      iex> PlayBalance.compute_today(user)
      {:ok, %{
        earned_today: 27.5,
        used_today: 10.0,
        exercise_minutes: 15.0,
        today_net: 17.5,
        playtime: 32.5
      }}
  """
  def compute_today(
        user,
        now \\ DateTime.utc_now(),
        time_source_opts \\ [],
        get_elapsed_minutes \\ &@time_source.get_elapsed_minutes/2
      ) do
    with {:ok, activities} <- @persistence.list_activities(user.id),
         {:ok, earned_today} <-
           sum_today_earned(activities, user, now, time_source_opts, get_elapsed_minutes),
         {:ok, exercise_minutes} <- get_manual_sync_total(user),
         {:ok, used_today} <- PlaytimeUsed.total_used_today(user.id, user.timezone, now) do
      today_net = earned_today - used_today

      {:ok,
       %{
         earned_today: earned_today,
         used_today: used_today,
         exercise_minutes: exercise_minutes,
         today_net: today_net,
         playtime: today_net + exercise_minutes
       }}
    end
  end

  defp sum_today_earned(activities, user, now, time_source_opts, get_elapsed_minutes) do
    wrapped = fn activity, opts -> get_elapsed_minutes.(activity, opts ++ time_source_opts) end

    total =
      Enum.reduce(activities, 0.0, fn activity, acc ->
        case today_activity_minutes(activity, user, now, wrapped) do
          {:ok, %{play_minutes: play_minutes}} -> acc + play_minutes
          {:error, _reason} -> acc
        end
      end)

    {:ok, total}
  end

  # Private functions

  defp compute_timing_derived_total(user, time_source_opts) do
    with {:ok, activities} <- @persistence.list_activities(user.id) do
      total =
        Enum.reduce(activities, 0.0, fn activity, acc ->
          case @time_source.get_elapsed_minutes(activity, time_source_opts) do
            {:ok, minutes} ->
              acc + minutes * activity.multiplier

            {:error, _reason} ->
              # Skip activities that fail to retrieve time
              acc
          end
        end)

      {:ok, total}
    end
  end

  defp get_manual_sync_total(user) do
    @persistence.get_manual_sync_total(user.id)
  end

  defp get_playtime_used_total(user) do
    @persistence.total_playtime_used(user.id)
  end
end
