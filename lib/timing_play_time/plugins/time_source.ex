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

  @doc """
  Lists individual time entries for a list of activities, batched into one
  logical fetch the same way `get_elapsed_minutes/2` is (ADR-0008) — entry
  dates and per-entry minutes, not pre-aggregated sums.

  Powers the Entry Expiry Window / Entry Consumption Ledger (ADR-0010): that
  ledger needs to replay consumption against individual entries, which an
  aggregate total can't support. This is a separate call from
  `get_elapsed_minutes/2` rather than a superset it's derived from, because
  the debug-only Play Balance reveal (ADR-0008) must keep fetching exactly
  as before — unaffected by this callback's existence.

  Unlike `get_elapsed_minutes/2`, `:from` is caller-supplied rather than
  adapter-owned and bounded by any Activity's Activated At — Activated At
  carries no functional weight on the user-facing path this feeds
  (ADR-0010). `PlayBalance.compute_today/4` omits `:from` (unbounded) when
  fetching entries for the Entry Consumption Ledger's replay — the ledger
  needs full history to correctly replay consumption, and instead protects
  Reserve from an ancient backlog silently absorbing new spending via
  `EntryLedger.replay/4`'s `window_start` argument, not via a bounded
  fetch (see `TimingPlayTime.EntryLedger`'s moduledoc for why pre-filtering
  entries by date doesn't work here). `week_activity_minutes/3` is the
  other caller, and does pass `:from` — its per-Activity "This Week" figure
  is a plain windowed sum with no ledger involved, so bounding the fetch is
  the right (and cheaper) tool there.

  ## Parameters
    * `activities` - The Activity structs to fetch entries for
    * `opts` - Options for filtering time entries:
      * `:from` - Start datetime (defaults to unbounded — see above)
      * `:to` - End datetime (defaults to now)

  ## Returns
    * `{:ok, entries_by_identifier}` - `entries_by_identifier` is a map keyed
      by each activity's `time_source_identifier`, each value a list of
      `%{start_date: DateTime.t(), minutes: float()}` (raw Timing minutes,
      not yet multiplied by the Activity's Multiplier)
    * `{:error, reason}` - If the time source is unavailable or query fails

  ## Examples

      iex> list_entries([%Activity{time_source_identifier: "proj-123"}], [])
      {:ok, %{"proj-123" => [%{start_date: ~U[2026-08-01 09:00:00Z], minutes: 30.0}]}}

      iex> list_entries([], [])
      {:ok, %{}}
  """
  @callback list_entries(activities :: [map()], opts :: keyword()) ::
              {:ok, %{optional(String.t()) => [%{start_date: DateTime.t(), minutes: float()}]}}
              | {:error, term()}
end
