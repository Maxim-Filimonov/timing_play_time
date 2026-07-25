defmodule TimingPlayTime.PlayBalance do
  @moduledoc """
  Calculates the current Play Balance.

  Play Balance = Timing-Derived Earned Total + Manual Sync - Playtime Used Total

  Where:
  - Timing-Derived Earned Total: Sum of (elapsed minutes × multiplier) for all active Activities
  - Manual Sync: Absolute total from external source (e.g., exercise app)
  - Playtime Used Total: Sum of all logged playtime usage
  """

  alias TimingPlayTime.LocalDay

  @persistence Application.compile_env!(:timing_play_time, :persistence_adapter)
  @time_source Application.compile_env!(:timing_play_time, :time_source_adapter)

  @doc """
  Computes the current Play Balance.

  Returns a map with:
  - `:total` - The net balance (can be negative)
  - `:timing_derived_total` - Sum from Activities
  - `:manual_sync_total` - Manual sync value
  - `:playtime_used_total` - Total spent

  ## Examples

      iex> PlayBalance.compute()
      {:ok, %{
        total: 142.0,
        timing_derived_total: 187.0,
        manual_sync_total: 0.0,
        playtime_used_total: 45.0
      }}
  """
  def compute do
    with {:ok, timing_derived} <- compute_timing_derived_total(),
         {:ok, manual_sync} <- get_manual_sync_total(),
         {:ok, playtime_used} <- get_playtime_used_total() do
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
  (the local calendar day, per ADR-0005), for the dashboard's per-Activity
  breakdown.

  `from` is the later of the local start-of-day and the Activity's
  Activated At, so an Activity activated later today only counts from
  activation onward.

  ## Examples

      iex> PlayBalance.today_activity_minutes(activity)
      {:ok, %{minutes: 27.5, play_minutes: 41.25}}
  """
  def today_activity_minutes(activity, now \\ DateTime.utc_now()) do
    from = later(activity.activated_at, LocalDay.start_of_today(now))

    with {:ok, minutes} <- @time_source.get_elapsed_minutes(activity, from: from, to: now) do
      {:ok, %{minutes: minutes, play_minutes: minutes * activity.multiplier}}
    end
  end

  defp later(a, b) do
    if DateTime.compare(a, b) == :gt, do: a, else: b
  end

  # Private functions

  defp compute_timing_derived_total do
    case @persistence.list_activities() do
      {:ok, activities} ->
        total =
          Enum.reduce(activities, 0.0, fn activity, acc ->
            case @time_source.get_elapsed_minutes(activity) do
              {:ok, minutes} ->
                acc + minutes * activity.multiplier

              {:error, _reason} ->
                # Skip activities that fail to retrieve time
                acc
            end
          end)

        {:ok, total}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp get_manual_sync_total do
    @persistence.get_manual_sync_total()
  end

  defp get_playtime_used_total do
    @persistence.total_playtime_used()
  end
end
