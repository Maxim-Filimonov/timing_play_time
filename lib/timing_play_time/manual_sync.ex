defmodule TimingPlayTime.ManualSync do
  @moduledoc """
  Context for managing a User's Manual Sync total (ADR-0006).

  Provides a clean interface for setting and retrieving the manual sync total,
  which represents play minutes from external sources (e.g., exercise apps).
  """

  @persistence Application.compile_env!(:timing_play_time, :persistence_adapter)

  @doc """
  Gets a user's current manual sync total.

  ## Examples

      iex> get_total(user.id)
      {:ok, 0.0}
  """
  def get_total(user_id) do
    @persistence.get_manual_sync_total(user_id)
  end

  @doc """
  Sets a user's manual sync total (overwrites previous value).

  ## Examples

      iex> set_total(user.id, 150.5)
      {:ok, 150.5}
  """
  def set_total(user_id, minutes) when is_number(minutes) do
    @persistence.set_manual_sync_total(user_id, minutes)
  end
end
