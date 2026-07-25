defmodule TimingPlayTime.ManualSync do
  @moduledoc """
  Context for managing Manual Sync totals.

  Provides a clean interface for setting and retrieving the manual sync total,
  which represents play minutes from external sources (e.g., exercise apps).
  """

  @persistence Application.compile_env!(:timing_play_time, :persistence_adapter)

  @doc """
  Gets the current manual sync total.

  ## Examples

      iex> get_total()
      {:ok, 0.0}
  """
  def get_total do
    @persistence.get_manual_sync_total()
  end

  @doc """
  Sets the manual sync total (overwrites previous value).

  ## Examples

      iex> set_total(150.5)
      {:ok, 150.5}
  """
  def set_total(minutes) when is_number(minutes) do
    @persistence.set_manual_sync_total(minutes)
  end
end
