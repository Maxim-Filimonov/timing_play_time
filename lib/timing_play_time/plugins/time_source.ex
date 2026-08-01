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
  Gets elapsed minutes for a list of activities within a time range, in a
  single logical fetch — batching-vs-not is an adapter implementation
  detail, not something callers (e.g. `TimingPlayTime.PlayBalance`) decide.

  ## Parameters
    * `activities` - The Activity structs to fetch elapsed minutes for
    * `opts` - Options for filtering time entries:
      * `:to` - End datetime (defaults to now)
      * `:today_from` - Local-day boundary for the "today" split (see
        `TimingPlayTime.LocalDay`, ADR-0005). `nil` (the default) skips the
        "today" figure entirely, returning `nil` for every activity's
        `:today` key — this is how the no-configured-timezone case is
        handled by callers.

  `:from` for the cumulative side is adapter-owned (no caller override for
  the primary use case) — see ADR-0008 for why a shared earliest-activation
  cutoff is used across all given activities rather than one per activity.

  ## Returns
    * `{:ok, totals}` - `totals` is a map keyed by each activity's
      `time_source_identifier`, each value `%{cumulative: float(), today:
      float() | nil}`
    * `{:error, reason}` - If the time source is unavailable or query fails

  ## Examples

      iex> get_elapsed_minutes([%Activity{time_source_identifier: "proj-123", activated_at: ~U[2024-01-01 00:00:00Z]}], [])
      {:ok, %{"proj-123" => %{cumulative: 127.5, today: nil}}}

      iex> get_elapsed_minutes([], [])
      {:ok, %{}}
  """
  @callback get_elapsed_minutes(activities :: [map()], opts :: keyword()) ::
              {:ok, %{optional(String.t()) => %{cumulative: float(), today: float() | nil}}}
              | {:error, term()}
end
