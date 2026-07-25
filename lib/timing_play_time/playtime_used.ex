defmodule TimingPlayTime.PlaytimeUsed do
  @moduledoc """
  Context for managing Playtime Used records.

  Provides a clean interface for logging play time spent and retrieving usage history.
  """

  @persistence Application.compile_env!(:timing_play_time, :persistence_adapter)

  @doc """
  Logs playtime usage with the current timestamp.

  ## Examples

      iex> log_usage(30.0)
      {:ok, %{id: "...", minutes: 30.0, logged_at: ~U[...]}}
  """
  def log_usage(minutes) when is_number(minutes) do
    @persistence.log_playtime_used(minutes, DateTime.utc_now())
  end

  @doc """
  Logs playtime usage with a custom timestamp.

  ## Examples

      iex> log_usage(20.0, ~U[2024-01-15 10:30:00Z])
      {:ok, %{id: "...", minutes: 20.0, logged_at: ~U[2024-01-15 10:30:00Z]}}
  """
  def log_usage(minutes, logged_at) when is_number(minutes) do
    @persistence.log_playtime_used(minutes, logged_at)
  end

  @doc """
  Lists all playtime usage records.

  ## Examples

      iex> list_all()
      {:ok, [%{id: "...", minutes: 30.0, logged_at: ~U[...]}]}
  """
  def list_all do
    @persistence.list_playtime_used()
  end

  @doc """
  Gets the total sum of all playtime used.

  ## Examples

      iex> total_used()
      {:ok, 75.5}
  """
  def total_used do
    @persistence.total_playtime_used()
  end
end
