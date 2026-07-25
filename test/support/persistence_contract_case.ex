defmodule TimingPlayTime.PersistenceContractCase do
  @moduledoc """
  Shared behavioural contract every `TimingPlayTime.Plugins.Persistence`
  adapter must satisfy, run against each concrete adapter (per ADR-0004) so
  they stay interchangeable behind the behaviour.

  Usage:

      defmodule MyAdapterTest do
        use ExUnit.Case, async: true   # or `use TimingPlayTime.DataCase` for DB-backed adapters

        use TimingPlayTime.PersistenceContractCase,
          adapter: MyAdapter,
          cleanup: {MyAdapter, :clear_all_state}   # optional, {module, function}
      end
  """

  defmacro __using__(opts) do
    adapter = Keyword.fetch!(opts, :adapter)
    cleanup = Keyword.get(opts, :cleanup)

    quote do
      @persistence unquote(adapter)

      setup do
        case unquote(cleanup) do
          {module, fun} -> apply(module, fun, [])
          nil -> :ok
        end

        :ok
      end

      describe "activities" do
        test "list_activities/0 returns an empty list when none exist" do
          assert {:ok, []} = @persistence.list_activities()
        end

        test "create_activity/1 creates and returns the activity" do
          attrs = %{
            name: "Coding",
            time_source_identifier: "coding-proj-1",
            multiplier: 1.5,
            activated_at: DateTime.utc_now() |> DateTime.truncate(:second)
          }

          assert {:ok, activity} = @persistence.create_activity(attrs)
          assert activity.id
          assert activity.name == "Coding"
          assert activity.time_source_identifier == "coding-proj-1"
          assert activity.multiplier == 1.5
          assert activity.activated_at == attrs.activated_at
        end

        test "create_activity/1 defaults activated_at to now when not provided" do
          # A second of slack accounts for adapters (e.g. Sqlite's `utc_datetime`
          # column) that truncate sub-second precision on round-trip.
          before = DateTime.utc_now() |> DateTime.add(-1, :second)

          assert {:ok, activity} =
                   @persistence.create_activity(%{
                     name: "Reading",
                     time_source_identifier: "reading-proj-1",
                     multiplier: 1.0
                   })

          after_time = DateTime.utc_now() |> DateTime.add(1, :second)

          assert DateTime.compare(activity.activated_at, before) in [:gt, :eq]
          assert DateTime.compare(activity.activated_at, after_time) in [:lt, :eq]
        end

        test "get_activity/1 returns the activity by id" do
          {:ok, created} =
            @persistence.create_activity(%{
              name: "Exercise",
              time_source_identifier: "exercise-proj-1",
              multiplier: 1.0,
              activated_at: DateTime.utc_now() |> DateTime.truncate(:second)
            })

          assert {:ok, fetched} = @persistence.get_activity(created.id)
          assert fetched.id == created.id
          assert fetched.name == "Exercise"
        end

        test "get_activity/1 returns :not_found for a missing id" do
          assert {:error, :not_found} = @persistence.get_activity("nonexistent-id")
        end

        test "list_activities/0 returns all created activities" do
          {:ok, activity1} =
            @persistence.create_activity(%{
              name: "Coding",
              time_source_identifier: "coding-proj-1",
              multiplier: 1.5,
              activated_at: DateTime.utc_now() |> DateTime.truncate(:second)
            })

          {:ok, activity2} =
            @persistence.create_activity(%{
              name: "Learning",
              time_source_identifier: "learning-proj-1",
              multiplier: 2.0,
              activated_at: DateTime.utc_now() |> DateTime.truncate(:second)
            })

          assert {:ok, activities} = @persistence.list_activities()
          assert length(activities) == 2
          assert Enum.any?(activities, &(&1.id == activity1.id))
          assert Enum.any?(activities, &(&1.id == activity2.id))
        end

        test "update_activity/2 updates the given fields" do
          {:ok, activity} =
            @persistence.create_activity(%{
              name: "Original",
              time_source_identifier: "original-proj",
              multiplier: 1.0,
              activated_at: DateTime.utc_now() |> DateTime.truncate(:second)
            })

          assert {:ok, updated} =
                   @persistence.update_activity(activity.id, %{name: "Updated", multiplier: 2.5})

          assert updated.id == activity.id
          assert updated.name == "Updated"
          assert updated.multiplier == 2.5
          assert updated.time_source_identifier == "original-proj"
        end

        test "update_activity/2 returns :not_found for a missing id" do
          assert {:error, :not_found} = @persistence.update_activity("nonexistent", %{name: "Fail"})
        end

        test "delete_activity/1 deletes an existing activity" do
          {:ok, activity} =
            @persistence.create_activity(%{
              name: "ToDelete",
              time_source_identifier: "delete-proj",
              multiplier: 1.0,
              activated_at: DateTime.utc_now() |> DateTime.truncate(:second)
            })

          assert :ok = @persistence.delete_activity(activity.id)
          assert {:error, :not_found} = @persistence.get_activity(activity.id)
        end

        test "delete_activity/1 is a no-op for a missing id" do
          assert :ok = @persistence.delete_activity("nonexistent-id")
        end
      end

      describe "manual sync" do
        test "get_manual_sync_total/0 defaults to 0.0" do
          assert {:ok, 0.0} = @persistence.get_manual_sync_total()
        end

        test "set_manual_sync_total/1 sets and returns the new total" do
          assert {:ok, 250.0} = @persistence.set_manual_sync_total(250.0)
          assert {:ok, 250.0} = @persistence.get_manual_sync_total()
        end

        test "set_manual_sync_total/1 overwrites (not accumulates) the previous total" do
          {:ok, _} = @persistence.set_manual_sync_total(100.0)
          assert {:ok, 100.0} = @persistence.get_manual_sync_total()

          {:ok, _} = @persistence.set_manual_sync_total(200.0)
          assert {:ok, 200.0} = @persistence.get_manual_sync_total()
        end

        test "set_manual_sync_total/1 accepts zero" do
          {:ok, _} = @persistence.set_manual_sync_total(100.0)
          assert {:ok, 0.0} = @persistence.set_manual_sync_total(0.0)
          assert {:ok, 0.0} = @persistence.get_manual_sync_total()
        end
      end

      describe "playtime used" do
        test "list_playtime_used/0 returns an empty list when none exist" do
          assert {:ok, []} = @persistence.list_playtime_used()
        end

        test "log_playtime_used/2 creates and returns the usage record" do
          logged_at = ~U[2024-01-15 10:30:00Z]
          assert {:ok, usage} = @persistence.log_playtime_used(20.0, logged_at)
          assert usage.id
          assert usage.minutes == 20.0
          assert usage.logged_at == logged_at
        end

        test "list_playtime_used/0 returns all logged usage" do
          {:ok, _} = @persistence.log_playtime_used(10.0, DateTime.utc_now())
          {:ok, _} = @persistence.log_playtime_used(20.0, DateTime.utc_now())

          assert {:ok, usages} = @persistence.list_playtime_used()
          assert length(usages) == 2
        end

        test "total_playtime_used/0 defaults to 0.0" do
          assert {:ok, 0.0} = @persistence.total_playtime_used()
        end

        test "total_playtime_used/0 sums all logged usage" do
          {:ok, _} = @persistence.log_playtime_used(10.0, DateTime.utc_now())
          {:ok, _} = @persistence.log_playtime_used(25.5, DateTime.utc_now())
          {:ok, _} = @persistence.log_playtime_used(15.0, DateTime.utc_now())

          assert {:ok, 50.5} = @persistence.total_playtime_used()
        end
      end
    end
  end
end
