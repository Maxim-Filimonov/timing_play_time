defmodule TimingPlayTime.LocalDay do
  @moduledoc """
  Computes calendar-day boundaries in a User's local timezone (`users.timezone`,
  ADR-0006 — formerly the required `TZ` environment variable, ADR-0005).
  """

  @doc """
  Returns the UTC instant of the start of today (local midnight) for the given
  UTC instant, in the given IANA timezone name.
  """
  def start_of_today(timezone, now \\ DateTime.utc_now()) do
    timezone
    |> to_date(now)
    |> DateTime.new!(~T[00:00:00], timezone)
    |> DateTime.shift_zone!("Etc/UTC")
  end

  @doc """
  Returns the local calendar date (in the given IANA timezone) that the
  given UTC instant falls on.
  """
  def to_date(timezone, instant) do
    instant |> DateTime.shift_zone!(timezone) |> DateTime.to_date()
  end
end
