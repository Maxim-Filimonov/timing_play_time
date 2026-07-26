defmodule TimingPlayTime.ActivityManager do
  @moduledoc """
  Context for managing a User's Activities (ADR-0006).

  Provides a clean interface to Activity CRUD operations,
  delegating to the configured Persistence plugin.
  """

  @persistence Application.compile_env!(:timing_play_time, :persistence_adapter)

  @doc """
  Lists all activities for a user.

  ## Examples

      iex> list_activities(user.id)
      {:ok, [%{id: "...", name: "Coding", ...}]}
  """
  def list_activities(user_id) do
    @persistence.list_activities(user_id)
  end

  @doc """
  Gets a single activity by ID, scoped to the given user.

  ## Examples

      iex> get_activity(user.id, "valid-id")
      {:ok, %{id: "...", name: "Coding", ...}}

      iex> get_activity(user.id, "invalid-id")
      {:error, :not_found}
  """
  def get_activity(user_id, id) do
    @persistence.get_activity(user_id, id)
  end

  @doc """
  Creates a new activity owned by the given user.

  ## Examples

      iex> create_activity(user.id, %{name: "Coding", time_source_identifier: "proj-1", multiplier: 1.5})
      {:ok, %{id: "...", name: "Coding", ...}}
  """
  def create_activity(user_id, attrs) do
    @persistence.create_activity(user_id, attrs)
  end

  @doc """
  Updates an existing activity, scoped to the given user.

  ## Examples

      iex> update_activity(user.id, "valid-id", %{name: "Updated"})
      {:ok, %{id: "...", name: "Updated", ...}}
  """
  def update_activity(user_id, id, attrs) do
    @persistence.update_activity(user_id, id, attrs)
  end

  @doc """
  Deletes an activity, scoped to the given user.

  ## Examples

      iex> delete_activity(user.id, "valid-id")
      :ok
  """
  def delete_activity(user_id, id) do
    @persistence.delete_activity(user_id, id)
  end
end
