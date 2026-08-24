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
  alias TimingPlayTime.Plugins.Persistence.Sqlite.EntryConsumption
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

  @impl true
  def record_entry_consumption(user_id, activity_id, time_entry_id, minutes) do
    insert_or_increment_consumption(user_id, activity_id, time_entry_id, minutes)
    |> to_result(& &1.consumed_minutes)
  end

  @impl true
  def list_entry_consumption(user_id) do
    rows =
      EntryConsumption
      |> where([c], c.user_id == ^user_id)
      |> Repo.all()
      |> Enum.map(&entry_consumption_to_map/1)

    {:ok, rows}
  end

  @impl true
  def record_entry_consumptions(user_id, consumptions) do
    Repo.transaction(fn ->
      apply_consumptions(user_id, consumptions)
      length(consumptions)
    end)
  end

  @impl true
  def record_spend(user_id, consumptions, minutes, logged_at) do
    Repo.transaction(fn ->
      apply_consumptions(user_id, consumptions)

      case log_playtime_used(user_id, minutes, logged_at) do
        {:ok, usage} -> usage
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end)
  end

  # Rolls the surrounding transaction back on the first failing delta, so
  # both write paths that use it (`record_spend/4`, `record_entry_consumptions/2`)
  # are all-or-nothing.
  defp apply_consumptions(user_id, consumptions) do
    Enum.each(consumptions, fn %{activity_id: activity_id, time_entry_id: time_entry_id, minutes: delta} ->
      case insert_or_increment_consumption(user_id, activity_id, time_entry_id, delta) do
        {:ok, _row} -> :ok
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end)
  end

  # Atomic upsert-increment (`ON CONFLICT ... DO UPDATE SET consumed_minutes
  # = consumed_minutes + ?`), rather than a separate read-then-write — two
  # concurrent calls for the same {user_id, activity_id, time_entry_id}
  # would otherwise race: both could read the same pre-write value and one's
  # increment would silently clobber the other's (ADR-0012).
  #
  # This makes the *increment* atomic, and nothing more. The wider
  # read-modify-write a spend performs — `PlayBalance.log_spend/6` reading
  # current consumption, computing a FIFO draw-down, then writing deltas —
  # is not serialized here: two concurrent spends would each draw the same
  # entries down and this would faithfully sum both, pushing an entry's
  # consumed_minutes past its earned play_minutes. The dashboard prevents
  # the realistic trigger (double-submit) at the UI, via phx-disable-with.
  defp insert_or_increment_consumption(user_id, activity_id, time_entry_id, minutes) do
    increment_query = from(c in EntryConsumption, update: [inc: [consumed_minutes: ^minutes]])

    %EntryConsumption{}
    |> EntryConsumption.changeset(%{
      user_id: user_id,
      activity_id: activity_id,
      time_entry_id: time_entry_id,
      consumed_minutes: minutes
    })
    |> Repo.insert(
      on_conflict: increment_query,
      conflict_target: [:user_id, :activity_id, :time_entry_id],
      returning: true
    )
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

  defp entry_consumption_to_map(%EntryConsumption{} = row) do
    %{
      activity_id: row.activity_id,
      time_entry_id: row.time_entry_id,
      consumed_minutes: row.consumed_minutes
    }
  end
end
