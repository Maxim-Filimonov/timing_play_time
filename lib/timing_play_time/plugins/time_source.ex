defmodule TimingPlayTime.Plugins.TimeSource do
  @moduledoc """
  Behaviour for time source plugins that report elapsed time on activities.

  This allows swapping between different time tracking backends (e.g., Timing app via MCP,
  manual entries, other tracking tools) without changing the core domain logic.

  Per ADR-0007, there is no global boot-time connection: the dashboard
  LiveView opens one connection per mount via `connect/1`, using that
  session's user's stored Integration credentials, and reuses it across its
  60-second live-refresh timer.
  """

  @doc """
  Opens a connection using a user's Integration credentials (the map stored
  in `TimingPlayTime.Accounts.Integration.credentials` — shape is owned by
  the adapter). The caller is responsible for the connection's lifetime; for
  the dashboard LiveView, that means it dies naturally with the LiveView
  process when the tab closes.

  ## Returns
    * `{:ok, client}` - Opaque handle, passed back in as `opts[:client]`
    * `{:error, reason}` - If the connection can't be established
  """
  @callback connect(credentials :: map()) :: {:ok, term()} | {:error, term()}

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
