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

    case activity.time_source_identifier do
      "coding-" <> _ -> 45.0 * days_active
      "learning-" <> _ -> 42.0 * days_active
      "exercise-" <> _ -> 36.0 * days_active
      "writing-" <> _ -> 30.0 * days_active
      _ -> 20.0 * days_active
    end
  end
end
