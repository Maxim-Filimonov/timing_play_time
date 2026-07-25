defmodule TimingPlayTime.Plugins.TimeSource do
  @moduledoc """
  Behaviour for time source plugins that report elapsed time on activities.

  This allows swapping between different time tracking backends (e.g., Timing app via MCP,
  manual entries, other tracking tools) without changing the core domain logic.
  """

  @doc """
  Gets elapsed minutes for a given activity within a time range.

  ## Parameters
    * `activity` - The Activity struct containing timing_project_id and activated_at
    * `opts` - Options for filtering time entries:
      * `:from` - Start datetime (defaults to activity.activated_at)
      * `:to` - End datetime (defaults to now)

  ## Returns
    * `{:ok, minutes}` - Total minutes elapsed as a float
    * `{:error, reason}` - If the time source is unavailable or query fails

  ## Examples

      iex> get_elapsed_minutes(%Activity{timing_project_id: "proj-123", activated_at: ~U[2024-01-01 00:00:00Z]})
      {:ok, 127.5}

      iex> get_elapsed_minutes(%Activity{timing_project_id: "invalid"})
      {:error, :project_not_found}
  """
  @callback get_elapsed_minutes(activity :: map(), opts :: keyword()) ::
              {:ok, float()} | {:error, term()}
end
