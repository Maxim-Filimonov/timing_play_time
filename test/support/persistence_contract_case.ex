defmodule TimingPlayTime.PersistenceContractCase do
  @moduledoc """
  Shared behavioural contract every `TimingPlayTime.Plugins.Persistence`
  adapter must satisfy, run against each concrete adapter (per ADR-0004) so
  they stay interchangeable behind the behaviour. Every callback is scoped
  to a `user_id` (ADR-0006) — the contract also asserts tenant isolation.

  Usage:

      defmodule MyAdapterTest do
        use ExUnit.Case, async: true   # or `use TimingPlayTime.DataCase` for DB-backed adapters

        use TimingPlayTime.PersistenceContractCase,
          adapter: MyAdapter,
          user_id_fixture: {TimingPlayTime.Support.Fixtures, :random_user_id},
          cleanup: {MyAdapter, :clear_all_state}   # optional, {module, function}
      end
  """

  defmacro __using__(opts) do
    adapter = Keyword.fetch!(opts, :adapter)
    cleanup = Keyword.get(opts, :cleanup)
    user_id_fixture = Keyword.fetch!(opts, :user_id_fixture)

    quote do
      @persistence unquote(adapter)

      setup do
        case unquote(cleanup) do
          {module, fun} -> apply(module, fun, [])
          nil -> :ok
        end

        {fixture_module, fixture_fun} = unquote(user_id_fixture)

        %{
          user_id: apply(fixture_module, fixture_fun, []),
          other_user_id: apply(fixture_module, fixture_fun, [])
        }
      end

      describe "activities" do
        test "list_activities/1 returns an empty list when none exist", %{user_id: user_id} do
          assert {:ok, []} = @persistence.list_activities(user_id)
        end

        test "create_activity/2 creates and returns the activity", %{user_id: user_id} do
          attrs = %{
            name: "Coding",
            time_source_identifier: "coding-proj-1",
            multiplier: 1.5,
            activated_at: DateTime.utc_now() |> DateTime.truncate(:second)
          }

          assert {:ok, activity} = @persistence.create_activity(user_id, attrs)
          assert activity.id
          assert activity.name == "Coding"
          assert activity.time_source_identifier == "coding-proj-1"
          assert activity.multiplier == 1.5
          assert activity.activated_at == attrs.activated_at
        end

        test "create_activity/2 defaults activated_at to now when not provided", %{user_id: user_id} do
          # A second of slack accounts for adapters (e.g. Sqlite's `utc_datetime`
          # column) that truncate sub-second precision on round-trip.
          before = DateTime.utc_now() |> DateTime.add(-1, :second)

          assert {:ok, activity} =
                   @persistence.create_activity(user_id, %{
                     name: "Reading",
                     time_source_identifier: "reading-proj-1",
                     multiplier: 1.0
                   })

          after_time = DateTime.utc_now() |> DateTime.add(1, :second)

          assert DateTime.compare(activity.activated_at, before) in [:gt, :eq]
          assert DateTime.compare(activity.activated_at, after_time) in [:lt, :eq]
        end

        test "get_activity/2 returns the activity by id", %{user_id: user_id} do
          {:ok, created} =
            @persistence.create_activity(user_id, %{
              name: "Exercise",
              time_source_identifier: "exercise-proj-1",
              multiplier: 1.0,
              activated_at: DateTime.utc_now() |> DateTime.truncate(:second)
            })

          assert {:ok, fetched} = @persistence.get_activity(user_id, created.id)
          assert fetched.id == created.id
          assert fetched.name == "Exercise"
        end

        test "get_activity/2 returns :not_found for a missing id", %{user_id: user_id} do
          assert {:error, :not_found} = @persistence.get_activity(user_id, "nonexistent-id")
        end

        test "get_activity/2 returns :not_found for another user's activity", %{
          user_id: user_id,
          other_user_id: other_user_id
        } do
          {:ok, activity} =
            @persistence.create_activity(other_user_id, %{
              name: "Someone Else's",
              time_source_identifier: "other-proj",
              multiplier: 1.0,
              activated_at: DateTime.utc_now() |> DateTime.truncate(:second)
            })

          assert {:error, :not_found} = @persistence.get_activity(user_id, activity.id)
        end

        test "list_activities/1 returns all created activities for that user", %{user_id: user_id} do
          {:ok, activity1} =
            @persistence.create_activity(user_id, %{
              name: "Coding",
              time_source_identifier: "coding-proj-1",
              multiplier: 1.5,
              activated_at: DateTime.utc_now() |> DateTime.truncate(:second)
            })

          {:ok, activity2} =
            @persistence.create_activity(user_id, %{
              name: "Learning",
              time_source_identifier: "learning-proj-1",
              multiplier: 2.0,
              activated_at: DateTime.utc_now() |> DateTime.truncate(:second)
            })

          assert {:ok, activities} = @persistence.list_activities(user_id)
          assert length(activities) == 2
          assert Enum.any?(activities, &(&1.id == activity1.id))
          assert Enum.any?(activities, &(&1.id == activity2.id))
        end

        test "list_activities/1 does not include another user's activities", %{
          user_id: user_id,
          other_user_id: other_user_id
        } do
          {:ok, _mine} =
            @persistence.create_activity(user_id, %{
              name: "Mine",
              time_source_identifier: "mine-proj",
              multiplier: 1.0,
              activated_at: DateTime.utc_now() |> DateTime.truncate(:second)
            })

          {:ok, _theirs} =
            @persistence.create_activity(other_user_id, %{
              name: "Theirs",
              time_source_identifier: "theirs-proj",
              multiplier: 1.0,
              activated_at: DateTime.utc_now() |> DateTime.truncate(:second)
            })

          assert {:ok, activities} = @persistence.list_activities(user_id)
          assert [%{name: "Mine"}] = activities
        end

        test "update_activity/3 updates the given fields", %{user_id: user_id} do
          {:ok, activity} =
            @persistence.create_activity(user_id, %{
              name: "Original",
              time_source_identifier: "original-proj",
              multiplier: 1.0,
              activated_at: DateTime.utc_now() |> DateTime.truncate(:second)
            })

          assert {:ok, updated} =
                   @persistence.update_activity(user_id, activity.id, %{
                     name: "Updated",
                     multiplier: 2.5
                   })

          assert updated.id == activity.id
          assert updated.name == "Updated"
          assert updated.multiplier == 2.5
          assert updated.time_source_identifier == "original-proj"
        end

        test "update_activity/3 returns :not_found for a missing id", %{user_id: user_id} do
          assert {:error, :not_found} =
                   @persistence.update_activity(user_id, "nonexistent", %{name: "Fail"})
        end

        test "update_activity/3 returns :not_found for another user's activity", %{
          user_id: user_id,
          other_user_id: other_user_id
        } do
          {:ok, activity} =
            @persistence.create_activity(other_user_id, %{
              name: "Theirs",
              time_source_identifier: "theirs-proj",
              multiplier: 1.0,
              activated_at: DateTime.utc_now() |> DateTime.truncate(:second)
            })

          assert {:error, :not_found} =
                   @persistence.update_activity(user_id, activity.id, %{name: "Hijacked"})
        end

        test "delete_activity/2 deletes an existing activity", %{user_id: user_id} do
          {:ok, activity} =
            @persistence.create_activity(user_id, %{
              name: "ToDelete",
              time_source_identifier: "delete-proj",
              multiplier: 1.0,
              activated_at: DateTime.utc_now() |> DateTime.truncate(:second)
            })

          assert :ok = @persistence.delete_activity(user_id, activity.id)
          assert {:error, :not_found} = @persistence.get_activity(user_id, activity.id)
        end

        test "delete_activity/2 is a no-op for a missing id", %{user_id: user_id} do
          assert :ok = @persistence.delete_activity(user_id, "nonexistent-id")
        end

        test "delete_activity/2 does not delete another user's activity", %{
          user_id: user_id,
          other_user_id: other_user_id
        } do
          {:ok, activity} =
            @persistence.create_activity(other_user_id, %{
              name: "Theirs",
              time_source_identifier: "theirs-proj",
              multiplier: 1.0,
              activated_at: DateTime.utc_now() |> DateTime.truncate(:second)
            })

          assert :ok = @persistence.delete_activity(user_id, activity.id)
          assert {:ok, _still_there} = @persistence.get_activity(other_user_id, activity.id)
        end
      end

      describe "manual sync" do
        test "get_manual_sync_total/1 defaults to 0.0", %{user_id: user_id} do
          assert {:ok, 0.0} = @persistence.get_manual_sync_total(user_id)
        end

        test "set_manual_sync_total/2 sets and returns the new total", %{user_id: user_id} do
          assert {:ok, 250.0} = @persistence.set_manual_sync_total(user_id, 250.0)
          assert {:ok, 250.0} = @persistence.get_manual_sync_total(user_id)
        end

        test "set_manual_sync_total/2 overwrites (not accumulates) the previous total", %{
          user_id: user_id
        } do
          {:ok, _} = @persistence.set_manual_sync_total(user_id, 100.0)
          assert {:ok, 100.0} = @persistence.get_manual_sync_total(user_id)

          {:ok, _} = @persistence.set_manual_sync_total(user_id, 200.0)
          assert {:ok, 200.0} = @persistence.get_manual_sync_total(user_id)
        end

        test "set_manual_sync_total/2 accepts zero", %{user_id: user_id} do
          {:ok, _} = @persistence.set_manual_sync_total(user_id, 100.0)
          assert {:ok, 0.0} = @persistence.set_manual_sync_total(user_id, 0.0)
          assert {:ok, 0.0} = @persistence.get_manual_sync_total(user_id)
        end

        test "manual sync total is isolated per user", %{
          user_id: user_id,
          other_user_id: other_user_id
        } do
          {:ok, _} = @persistence.set_manual_sync_total(other_user_id, 999.0)

          assert {:ok, 0.0} = @persistence.get_manual_sync_total(user_id)
        end
      end

      describe "playtime used" do
        test "list_playtime_used/1 returns an empty list when none exist", %{user_id: user_id} do
          assert {:ok, []} = @persistence.list_playtime_used(user_id)
        end

        test "log_playtime_used/3 creates and returns the usage record", %{user_id: user_id} do
          logged_at = ~U[2024-01-15 10:30:00Z]
          assert {:ok, usage} = @persistence.log_playtime_used(user_id, 20.0, logged_at)
          assert usage.id
          assert usage.minutes == 20.0
          assert usage.logged_at == logged_at
        end

        test "list_playtime_used/1 returns all logged usage for that user", %{user_id: user_id} do
          {:ok, _} = @persistence.log_playtime_used(user_id, 10.0, DateTime.utc_now())
          {:ok, _} = @persistence.log_playtime_used(user_id, 20.0, DateTime.utc_now())

          assert {:ok, usages} = @persistence.list_playtime_used(user_id)
          assert length(usages) == 2
        end

        test "total_playtime_used/1 defaults to 0.0", %{user_id: user_id} do
          assert {:ok, 0.0} = @persistence.total_playtime_used(user_id)
        end

        test "total_playtime_used/1 sums all logged usage for that user", %{user_id: user_id} do
          {:ok, _} = @persistence.log_playtime_used(user_id, 10.0, DateTime.utc_now())
          {:ok, _} = @persistence.log_playtime_used(user_id, 25.5, DateTime.utc_now())
          {:ok, _} = @persistence.log_playtime_used(user_id, 15.0, DateTime.utc_now())

          assert {:ok, 50.5} = @persistence.total_playtime_used(user_id)
        end

        test "playtime used is isolated per user", %{user_id: user_id, other_user_id: other_user_id} do
          {:ok, _} = @persistence.log_playtime_used(other_user_id, 999.0, DateTime.utc_now())

          assert {:ok, []} = @persistence.list_playtime_used(user_id)
          assert {:ok, 0.0} = @persistence.total_playtime_used(user_id)
        end
      end
    end
  end
end
