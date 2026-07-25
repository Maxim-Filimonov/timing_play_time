defmodule TimingPlayTime.LocalDay do
  @moduledoc """
  Computes calendar-day boundaries in the operator's local timezone, configured
  via the required `TZ` environment variable (ADR-0005).
  """

  @doc """
  Returns the UTC instant of the start of today (local midnight) for the given
  UTC instant, in the configured local timezone.
  """
  def start_of_today(now \\ DateTime.utc_now()) do
    timezone = Application.fetch_env!(:timing_play_time, :local_timezone)
    local_date = now |> DateTime.shift_zone!(timezone) |> DateTime.to_date()

    local_date
    |> DateTime.new!(~T[00:00:00], timezone)
    |> DateTime.shift_zone!("Etc/UTC")
  end
end
