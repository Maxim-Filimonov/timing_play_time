defmodule TimingPlayTime.Plugins.Persistence.Sqlite do
  @moduledoc """
  SQLite-backed implementation of `TimingPlayTime.Plugins.Persistence`,
  using the app's own Ecto `Repo`. See ADR-0004.

  Manual Sync is stored as an append-only log (each call to
  `set_manual_sync_total/1` inserts a row); `get_manual_sync_total/0`
  reads the most recent row by `inserted_at`.
  """

  @behaviour TimingPlayTime.Plugins.Persistence

  import Ecto.Query

  alias TimingPlayTime.Repo
  alias TimingPlayTime.Plugins.Persistence.Sqlite.Activity
  alias TimingPlayTime.Plugins.Persistence.Sqlite.ManualSync
  alias TimingPlayTime.Plugins.Persistence.Sqlite.PlaytimeUsed

  @impl true
  def list_activities do
    activities = Activity |> Repo.all() |> Enum.map(&activity_to_map/1)
    {:ok, activities}
  end

  @impl true
  def get_activity(id) do
    case Repo.get(Activity, id) do
      nil -> {:error, :not_found}
      activity -> {:ok, activity_to_map(activity)}
    end
  rescue
    Ecto.Query.CastError -> {:error, :not_found}
  end

  @impl true
  def create_activity(attrs) do
    %Activity{}
    |> Activity.changeset(attrs)
    |> Repo.insert()
    |> to_result(&activity_to_map/1)
  end

  @impl true
  def update_activity(id, attrs) do
    case Repo.get(Activity, id) do
      nil ->
        {:error, :not_found}

      activity ->
        activity
        |> Activity.changeset(attrs)
        |> Repo.update()
        |> to_result(&activity_to_map/1)
    end
  rescue
    Ecto.Query.CastError -> {:error, :not_found}
  end

  @impl true
  def delete_activity(id) do
    case Repo.get(Activity, id) do
      nil -> :ok
      activity -> with {:ok, _} <- Repo.delete(activity), do: :ok
    end
  rescue
    Ecto.Query.CastError -> :ok
  end

  @impl true
  def get_manual_sync_total do
    minutes =
      ManualSync
      |> order_by(desc: :inserted_at)
      |> limit(1)
      |> Repo.one()
      |> case do
        nil -> 0.0
        %ManualSync{minutes: minutes} -> minutes
      end

    {:ok, minutes}
  end

  @impl true
  def set_manual_sync_total(minutes) do
    %ManualSync{}
    |> ManualSync.changeset(%{minutes: minutes})
    |> Repo.insert()
    |> case do
      {:ok, %ManualSync{minutes: minutes}} -> {:ok, minutes}
      {:error, changeset} -> {:error, changeset}
    end
  end

  @impl true
  def log_playtime_used(minutes, logged_at \\ DateTime.utc_now()) do
    %PlaytimeUsed{}
    |> PlaytimeUsed.changeset(%{minutes: minutes, logged_at: logged_at})
    |> Repo.insert()
    |> to_result(&playtime_used_to_map/1)
  end

  @impl true
  def list_playtime_used do
    usages = PlaytimeUsed |> Repo.all() |> Enum.map(&playtime_used_to_map/1)
    {:ok, usages}
  end

  @impl true
  def total_playtime_used do
    total = PlaytimeUsed |> select([p], sum(p.minutes)) |> Repo.one()
    {:ok, total || 0.0}
  end

  # Private

  defp to_result({:ok, record}, mapper), do: {:ok, mapper.(record)}
  defp to_result({:error, changeset}, _mapper), do: {:error, changeset}

  defp activity_to_map(%Activity{} = activity) do
    %{
      id: activity.id,
      name: activity.name,
      time_source_identifier: activity.time_source_identifier,
      multiplier: activity.multiplier,
      activated_at: activity.activated_at
    }
  end

  defp playtime_used_to_map(%PlaytimeUsed{} = usage) do
    %{
      id: usage.id,
      minutes: usage.minutes,
      logged_at: usage.logged_at
    }
  end
end
