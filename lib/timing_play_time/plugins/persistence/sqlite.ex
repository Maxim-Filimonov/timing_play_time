defmodule TimingPlayTime.Plugins.Persistence.Sqlite do
  @moduledoc """
  SQLite-backed implementation of `TimingPlayTime.Plugins.Persistence`,
  using the app's own Ecto `Repo`. See ADR-0004.

  Manual Sync is stored as an append-only log (each call to
  `set_manual_sync_total/2` inserts a row); `get_manual_sync_total/1`
  reads the most recent row by `inserted_at`.

  Every function is scoped to a `user_id` (ADR-0006); a row belonging to a
  different user is treated the same as a missing one.
  """

  @behaviour TimingPlayTime.Plugins.Persistence

  import Ecto.Query

  alias TimingPlayTime.Repo
  alias TimingPlayTime.Plugins.Persistence.Sqlite.Activity
  alias TimingPlayTime.Plugins.Persistence.Sqlite.ManualSync
  alias TimingPlayTime.Plugins.Persistence.Sqlite.PlaytimeUsed

  @impl true
  def list_activities(user_id) do
    activities =
      Activity |> where([a], a.user_id == ^user_id) |> Repo.all() |> Enum.map(&activity_to_map/1)

    {:ok, activities}
  end

  @impl true
  def get_activity(user_id, id) do
    case fetch_activity(user_id, id) do
      {:ok, activity} -> {:ok, activity_to_map(activity)}
      {:error, :not_found} -> {:error, :not_found}
    end
  end

  @impl true
  def create_activity(user_id, attrs) do
    %Activity{}
    |> Activity.changeset(Map.put(attrs, :user_id, user_id))
    |> Repo.insert()
    |> to_result(&activity_to_map/1)
  end

  @impl true
  def update_activity(user_id, id, attrs) do
    case fetch_activity(user_id, id) do
      {:error, :not_found} ->
        {:error, :not_found}

      {:ok, activity} ->
        activity
        |> Activity.changeset(Map.delete(attrs, :user_id))
        |> Repo.update()
        |> to_result(&activity_to_map/1)
    end
  end

  @impl true
  def delete_activity(user_id, id) do
    case fetch_activity(user_id, id) do
      {:error, :not_found} -> :ok
      {:ok, activity} -> with {:ok, _} <- Repo.delete(activity), do: :ok
    end
  end

  @impl true
  def get_manual_sync_total(user_id) do
    minutes =
      ManualSync
      |> where([m], m.user_id == ^user_id)
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
  def set_manual_sync_total(user_id, minutes) do
    %ManualSync{}
    |> ManualSync.changeset(%{minutes: minutes, user_id: user_id})
    |> Repo.insert()
    |> to_result(fn %ManualSync{minutes: minutes} -> minutes end)
  end

  @impl true
  def log_playtime_used(user_id, minutes, logged_at \\ DateTime.utc_now()) do
    %PlaytimeUsed{}
    |> PlaytimeUsed.changeset(%{minutes: minutes, logged_at: logged_at, user_id: user_id})
    |> Repo.insert()
    |> to_result(&playtime_used_to_map/1)
  end

  @impl true
  def list_playtime_used(user_id) do
    usages =
      PlaytimeUsed
      |> where([p], p.user_id == ^user_id)
      |> Repo.all()
      |> Enum.map(&playtime_used_to_map/1)

    {:ok, usages}
  end

  @impl true
  def total_playtime_used(user_id) do
    total =
      PlaytimeUsed |> where([p], p.user_id == ^user_id) |> select([p], sum(p.minutes)) |> Repo.one()

    {:ok, total || 0.0}
  end

  # Private

  defp fetch_activity(user_id, id) do
    Activity
    |> where([a], a.user_id == ^user_id)
    |> Repo.get(id)
    |> case do
      nil -> {:error, :not_found}
      activity -> {:ok, activity}
    end
  rescue
    Ecto.Query.CastError -> {:error, :not_found}
  end

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
