defmodule TimingPlayTime.Plugins.TimeSource.Stub do
  @moduledoc """
  Stub implementation of TimeSource for development and testing.

  Returns hardcoded time entries to simulate the Timing app without requiring MCP integration.
  """

  @behaviour TimingPlayTime.Plugins.TimeSource

  @impl true
  def get_elapsed_minutes(activity, opts \\ []) do
    # Simulate different elapsed times based on time_source_identifier
    # In production, this would query the Timing app via MCP

    from = Keyword.get(opts, :from, activity.activated_at || DateTime.utc_now())
    to = Keyword.get(opts, :to, DateTime.utc_now())

    # Fractional days elapsed in the queried range, so sub-day ranges (e.g.
    # "today so far") simulate proportional minutes instead of always zero.
    days_active = DateTime.diff(to, from, :second) / 86_400

    # Simulate time entries based on project ID pattern
    base_minutes =
      case activity.time_source_identifier do
        "coding-" <> _ -> 45.0 * days_active
        "learning-" <> _ -> 42.0 * days_active
        "exercise-" <> _ -> 36.0 * days_active
        "writing-" <> _ -> 30.0 * days_active
        _ -> 20.0 * days_active
      end

    {:ok, base_minutes}
  rescue
    error ->
      {:error, {:stub_error, error}}
  end
end
