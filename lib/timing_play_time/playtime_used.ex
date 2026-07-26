defmodule TimingPlayTime.PlaytimeUsed do
  @moduledoc """
  Context for managing a User's Playtime Used records (ADR-0006).

  Provides a clean interface for logging play time spent and retrieving usage history.
  """

  @persistence Application.compile_env!(:timing_play_time, :persistence_adapter)

  @doc """
  Logs playtime usage for a user with the current timestamp.

  ## Examples

      iex> log_usage(user.id, 30.0)
      {:ok, %{id: "...", minutes: 30.0, logged_at: ~U[...]}}
  """
  def log_usage(user_id, minutes) when is_number(minutes) do
    @persistence.log_playtime_used(user_id, minutes, DateTime.utc_now())
  end

  @doc """
  Logs playtime usage for a user with a custom timestamp.

  ## Examples

      iex> log_usage(user.id, 20.0, ~U[2024-01-15 10:30:00Z])
      {:ok, %{id: "...", minutes: 20.0, logged_at: ~U[2024-01-15 10:30:00Z]}}
  """
  def log_usage(user_id, minutes, logged_at) when is_number(minutes) do
    @persistence.log_playtime_used(user_id, minutes, logged_at)
  end

  @doc """
  Lists all playtime usage records for a user.

  ## Examples

      iex> list_all(user.id)
      {:ok, [%{id: "...", minutes: 30.0, logged_at: ~U[...]}]}
  """
  def list_all(user_id) do
    @persistence.list_playtime_used(user_id)
  end

  @doc """
  Gets the total sum of a user's playtime used.

  ## Examples

      iex> total_used(user.id)
      {:ok, 75.5}
  """
  def total_used(user_id) do
    @persistence.total_playtime_used(user_id)
  end
end
