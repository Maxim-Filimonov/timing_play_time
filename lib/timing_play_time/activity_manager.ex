defmodule TimingPlayTime.ActivityManager do
  @moduledoc """
  Context for managing Activities.

  Provides a clean interface to Activity CRUD operations,
  delegating to the configured Persistence plugin.
  """

  @persistence Application.compile_env!(:timing_play_time, :persistence_adapter)

  @doc """
  Lists all activities.

  ## Examples

      iex> list_activities()
      {:ok, [%{id: "...", name: "Coding", ...}]}
  """
  def list_activities do
    @persistence.list_activities()
  end

  @doc """
  Gets a single activity by ID.

  ## Examples

      iex> get_activity("valid-id")
      {:ok, %{id: "...", name: "Coding", ...}}

      iex> get_activity("invalid-id")
      {:error, :not_found}
  """
  def get_activity(id) do
    @persistence.get_activity(id)
  end

  @doc """
  Creates a new activity.

  ## Examples

      iex> create_activity(%{name: "Coding", time_source_identifier: "proj-1", multiplier: 1.5})
      {:ok, %{id: "...", name: "Coding", ...}}
  """
  def create_activity(attrs) do
    @persistence.create_activity(attrs)
  end

  @doc """
  Updates an existing activity.

  ## Examples

      iex> update_activity("valid-id", %{name: "Updated"})
      {:ok, %{id: "...", name: "Updated", ...}}
  """
  def update_activity(id, attrs) do
    @persistence.update_activity(id, attrs)
  end

  @doc """
  Deletes an activity.

  ## Examples

      iex> delete_activity("valid-id")
      :ok
  """
  def delete_activity(id) do
    @persistence.delete_activity(id)
  end
end
