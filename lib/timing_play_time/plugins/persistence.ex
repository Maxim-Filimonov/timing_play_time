defmodule TimingPlayTime.Plugins.Persistence do
  @moduledoc """
  Behaviour for persistence plugins that store Activities, Manual Sync, and Playtime Used.

  This allows swapping between different storage backends (e.g., Fibery via MCP,
  local database, external APIs) without changing the core domain logic.

  Every callback is scoped to a `user_id` (ADR-0006) — adapters must only
  ever read or write rows belonging to that user; a mismatched id (someone
  else's row, or a stale id after account loss) must behave the same as a
  missing one (`{:error, :not_found}`), not leak another user's data.
  """

  @doc """
  Lists all active activities for a user.

  ## Returns
    * `{:ok, [activity]}` - List of activity maps
    * `{:error, reason}` - If retrieval fails
  """
  @callback list_activities(user_id :: String.t()) :: {:ok, [map()]} | {:error, term()}

  @doc """
  Gets a single activity by id, scoped to the given user.

  ## Returns
    * `{:ok, activity}` - The activity map
    * `{:error, :not_found}` - If the activity doesn't exist, or belongs to another user
    * `{:error, reason}` - If retrieval fails
  """
  @callback get_activity(user_id :: String.t(), id :: String.t()) ::
              {:ok, map()} | {:error, term()}

  @doc """
  Creates a new activity owned by the given user.

  ## Parameters
    * `attrs` - Map containing:
      * `:name` - Activity name (required)
      * `:time_source_identifier` - Timing project ID (required)
      * `:multiplier` - Multiplier factor (required, float)
      * `:activated_at` - Activation timestamp (defaults to now)

  ## Returns
    * `{:ok, activity}` - The created activity
    * `{:error, reason}` - If creation fails
  """
  @callback create_activity(user_id :: String.t(), attrs :: map()) ::
              {:ok, map()} | {:error, term()}

  @doc """
  Updates an existing activity, scoped to the given user.

  ## Returns
    * `{:ok, activity}` - The updated activity
    * `{:error, :not_found}` - If the activity doesn't exist, or belongs to another user
    * `{:error, reason}` - If update fails
  """
  @callback update_activity(user_id :: String.t(), id :: String.t(), attrs :: map()) ::
              {:ok, map()} | {:error, term()}

  @doc """
  Deletes an activity, scoped to the given user.

  ## Returns
    * `:ok` - Successfully deleted (or already absent for this user)
    * `{:error, reason}` - If deletion fails
  """
  @callback delete_activity(user_id :: String.t(), id :: String.t()) :: :ok | {:error, term()}

  @doc """
  Gets the current Manual Sync total for a user.

  ## Returns
    * `{:ok, minutes}` - Total minutes as a float
    * `{:error, reason}` - If retrieval fails
  """
  @callback get_manual_sync_total(user_id :: String.t()) :: {:ok, float()} | {:error, term()}

  @doc """
  Sets a user's Manual Sync total (overwrites previous value).

  ## Returns
    * `{:ok, minutes}` - The new total
    * `{:error, reason}` - If update fails
  """
  @callback set_manual_sync_total(user_id :: String.t(), minutes :: float()) ::
              {:ok, float()} | {:error, term()}

  @doc """
  Logs playtime usage for a user.

  ## Parameters
    * `minutes` - Minutes spent (float)
    * `logged_at` - Timestamp (defaults to now)

  ## Returns
    * `{:ok, usage}` - The created usage record
    * `{:error, reason}` - If creation fails
  """
  @callback log_playtime_used(user_id :: String.t(), minutes :: float(), logged_at :: DateTime.t()) ::
              {:ok, map()} | {:error, term()}

  @doc """
  Lists all playtime usage records for a user.

  ## Returns
    * `{:ok, [usage]}` - List of usage records
    * `{:error, reason}` - If retrieval fails
  """
  @callback list_playtime_used(user_id :: String.t()) :: {:ok, [map()]} | {:error, term()}

  @doc """
  Gets the total sum of a user's playtime used.

  ## Returns
    * `{:ok, minutes}` - Total minutes used as a float
    * `{:error, reason}` - If calculation fails
  """
  @callback total_playtime_used(user_id :: String.t()) :: {:ok, float()} | {:error, term()}

  @doc """
  Records that `minutes` of a specific Timing entry's Play Minutes have
  been consumed by a spend, for the Entry Consumption Ledger (ADR-0012).
  Adds to any minutes already recorded against that same `{activity_id,
  time_entry_id}` — a caller draws down an entry over multiple calls (one
  per spend), never overwrites what a previous spend already recorded.

  ## Returns
    * `{:ok, total_consumed}` - The entry's new cumulative consumed minutes
    * `{:error, reason}` - If the write fails
  """
  @callback record_entry_consumption(
              user_id :: String.t(),
              activity_id :: String.t(),
              time_entry_id :: String.t(),
              minutes :: float()
            ) :: {:ok, float()} | {:error, term()}

  @doc """
  Lists every Timing entry a User has ever drawn on, each with its
  cumulative consumed minutes (ADR-0012's Entry Consumption Ledger). Sparse
  — an entry nobody's spent against has no row here at all.

  ## Returns
    * `{:ok, [%{activity_id:, time_entry_id:, consumed_minutes:}]}`
    * `{:error, reason}` - If retrieval fails
  """
  @callback list_entry_consumption(user_id :: String.t()) :: {:ok, [map()]} | {:error, term()}

  @doc """
  Atomically records every given consumption delta (each added to that
  entry's existing cumulative total, same as `record_entry_consumption/4`)
  and logs the Playtime Used record for the spend that caused them, as one
  indivisible write (ADR-0012) — a spend either fully lands (every entry's
  draw-down and the usage record together) or none of it does, so a
  mid-write failure can never leave entries marked as consumed with no
  corresponding usage, or a logged usage with silently-missing draw-down.

  ## Parameters
    * `consumptions` - a list of `%{activity_id:, time_entry_id:,
      minutes:}` deltas to add; may be empty (a fully unmatched, all-deficit
      spend still logs its usage record)
    * `minutes` / `logged_at` - the usage record itself, same as
      `log_playtime_used/3`

  ## Returns
    * `{:ok, usage}` - the created usage record
    * `{:error, reason}` - if the write fails; nothing is left partially
      applied
  """
  @callback record_spend(
              user_id :: String.t(),
              consumptions :: [map()],
              minutes :: float(),
              logged_at :: DateTime.t()
            ) :: {:ok, map()} | {:error, term()}
end
