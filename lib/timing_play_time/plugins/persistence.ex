defmodule TimingPlayTime.Plugins.Persistence do
  @moduledoc """
  Behaviour for persistence plugins that store Activities, Manual Sync, and Playtime Used.

  This allows swapping between different storage backends (e.g., Fibery via MCP,
  local database, external APIs) without changing the core domain logic.
  """

  @doc """
  Lists all active activities.

  ## Returns
    * `{:ok, [activity]}` - List of activity maps
    * `{:error, reason}` - If retrieval fails
  """
  @callback list_activities() :: {:ok, [map()]} | {:error, term()}

  @doc """
  Gets a single activity by ID.

  ## Returns
    * `{:ok, activity}` - The activity map
    * `{:error, :not_found}` - If activity doesn't exist
    * `{:error, reason}` - If retrieval fails
  """
  @callback get_activity(id :: String.t()) :: {:ok, map()} | {:error, term()}

  @doc """
  Creates a new activity.

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
  @callback create_activity(attrs :: map()) :: {:ok, map()} | {:error, term()}

  @doc """
  Updates an existing activity.

  ## Returns
    * `{:ok, activity}` - The updated activity
    * `{:error, reason}` - If update fails
  """
  @callback update_activity(id :: String.t(), attrs :: map()) ::
              {:ok, map()} | {:error, term()}

  @doc """
  Deletes an activity.

  ## Returns
    * `:ok` - Successfully deleted
    * `{:error, reason}` - If deletion fails
  """
  @callback delete_activity(id :: String.t()) :: :ok | {:error, term()}

  @doc """
  Gets the current Manual Sync total.

  ## Returns
    * `{:ok, minutes}` - Total minutes as a float
    * `{:error, reason}` - If retrieval fails
  """
  @callback get_manual_sync_total() :: {:ok, float()} | {:error, term()}

  @doc """
  Sets the Manual Sync total (overwrites previous value).

  ## Returns
    * `{:ok, minutes}` - The new total
    * `{:error, reason}` - If update fails
  """
  @callback set_manual_sync_total(minutes :: float()) :: {:ok, float()} | {:error, term()}

  @doc """
  Logs playtime usage.

  ## Parameters
    * `minutes` - Minutes spent (float)
    * `logged_at` - Timestamp (defaults to now)

  ## Returns
    * `{:ok, usage}` - The created usage record
    * `{:error, reason}` - If creation fails
  """
  @callback log_playtime_used(minutes :: float(), logged_at :: DateTime.t()) ::
              {:ok, map()} | {:error, term()}

  @doc """
  Lists all playtime usage records.

  ## Returns
    * `{:ok, [usage]}` - List of usage records
    * `{:error, reason}` - If retrieval fails
  """
  @callback list_playtime_used() :: {:ok, [map()]} | {:error, term()}

  @doc """
  Gets the total sum of all playtime used.

  ## Returns
    * `{:ok, minutes}` - Total minutes used as a float
    * `{:error, reason}` - If calculation fails
  """
  @callback total_playtime_used() :: {:ok, float()} | {:error, term()}
end
