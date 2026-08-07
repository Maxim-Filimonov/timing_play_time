defmodule TimingPlayTime.Plugins.TimeSource.Stub do
  @moduledoc """
  Stub implementation of TimeSource for development and testing.

  Returns hardcoded time entries to simulate the Timing app without requiring MCP integration.

  Implements the same plural `get_elapsed_minutes/2` contract as the real
  Timing adapter, but isn't required to batch internally (ADR-0008) — it
  simply loops over the given Activities, computing each one's simulated
  minutes independently.
  """

  @behaviour TimingPlayTime.Plugins.TimeSource

  @impl true
  def connect(_credentials), do: {:ok, :stub_client}

  @impl true
  def get_elapsed_minutes(activities, opts \\ [])

  def get_elapsed_minutes(activities, opts) do
    to = Keyword.get(opts, :to, DateTime.utc_now())
    today_from = Keyword.get(opts, :today_from)

    totals =
      Map.new(activities, fn activity ->
        cumulative = simulate_minutes(activity, activity.activated_at || to, to)
        today = if today_from, do: simulate_minutes(activity, today_from, to)

        {activity.time_source_identifier, %{cumulative: cumulative, today: today}}
      end)

    {:ok, totals}
  rescue
    error ->
      {:error, {:stub_error, error}}
  end

  # Fractional days elapsed in the queried range, so sub-day ranges (e.g.
  # "today so far") simulate proportional minutes instead of always zero.
  # Rate varies by time_source_identifier pattern to simulate different
  # projects.
  defp simulate_minutes(activity, from, to) do
    days_active = DateTime.diff(to, from, :second) / 86_400
    daily_rate(activity) * days_active
  end

  @impl true
  def list_entries(activities, opts \\ [])

  def list_entries(activities, opts) do
    to = Keyword.get(opts, :to, DateTime.utc_now())

    entries =
      Map.new(activities, fn activity ->
        {activity.time_source_identifier, simulate_entries(activity, to)}
      end)

    {:ok, entries}
  rescue
    error ->
      {:error, {:stub_error, error}}
  end

  # One synthetic entry per elapsed calendar day since `activated_at` (or a
  # single same-day entry when unset), each worth a full day's rate at that
  # day's UTC midnight — real dated entries, unlike get_elapsed_minutes/2's
  # continuous day-fraction simulation, so the Entry Consumption Ledger has
  # something to expire and draw down.
  defp simulate_entries(activity, to) do
    from = activity.activated_at || to
    rate = daily_rate(activity)
    from_date = DateTime.to_date(from)
    to_date = DateTime.to_date(to)
    days = max(Date.diff(to_date, from_date), 0)

    for offset <- 0..days do
      start_date = from_date |> Date.add(offset) |> DateTime.new!(~T[00:00:00], "Etc/UTC")
      %{start_date: start_date, minutes: rate}
    end
  end

  defp daily_rate(activity) do
    case activity.time_source_identifier do
      "coding-" <> _ -> 45.0
      "learning-" <> _ -> 42.0
      "exercise-" <> _ -> 36.0
      "writing-" <> _ -> 30.0
      _ -> 20.0
    end
  end
end
