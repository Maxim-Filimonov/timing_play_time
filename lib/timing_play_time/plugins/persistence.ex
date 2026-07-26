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
end
