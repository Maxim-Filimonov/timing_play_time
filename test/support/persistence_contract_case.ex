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

        test "create_activity/2 stores and returns effect: :negative when given it", %{
          user_id: user_id
        } do
          assert {:ok, activity} =
                   @persistence.create_activity(user_id, %{
                     name: "YouTube",
                     time_source_identifier: "youtube-proj-1",
                     multiplier: 2.0,
                     effect: :negative
                   })

          assert activity.effect == :negative

          assert {:ok, activities} = @persistence.list_activities(user_id)
          assert Enum.find(activities, &(&1.id == activity.id)).effect == :negative

          assert {:ok, fetched} = @persistence.get_activity(user_id, activity.id)
          assert fetched.effect == :negative
        end

        test "create_activity/2 defaults effect to :positive when omitted", %{user_id: user_id} do
          assert {:ok, activity} =
                   @persistence.create_activity(user_id, %{
                     name: "Coding",
                     time_source_identifier: "coding-proj-1",
                     multiplier: 1.5
                   })

          assert activity.effect == :positive
        end

        test "create_activity/2 normalises the string \"negative\" to the atom", %{user_id: user_id} do
          assert {:ok, activity} =
                   @persistence.create_activity(user_id, %{
                     name: "YouTube",
                     time_source_identifier: "youtube-proj-1",
                     multiplier: 2.0,
                     effect: "negative"
                   })

          assert activity.effect == :negative
        end

        test "create_activity/2 rejects a non-positive multiplier", %{user_id: user_id} do
          base = %{name: "Coding", time_source_identifier: "coding-proj-1"}

          assert {:error, _} = @persistence.create_activity(user_id, Map.put(base, :multiplier, 0.0))
          assert {:error, _} = @persistence.create_activity(user_id, Map.put(base, :multiplier, -1.0))
        end

        test "create_activity/2 rejects an unknown effect", %{user_id: user_id} do
          assert {:error, _} =
                   @persistence.create_activity(user_id, %{
                     name: "Coding",
                     time_source_identifier: "coding-proj-1",
                     multiplier: 1.5,
                     effect: :sideways
                   })
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
          assert fetched.effect == :positive
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
              effect: :negative,
              activated_at: DateTime.utc_now() |> DateTime.truncate(:second)
            })

          assert {:ok, activities} = @persistence.list_activities(user_id)
          assert length(activities) == 2
          assert Enum.any?(activities, &(&1.id == activity1.id))
          assert Enum.any?(activities, &(&1.id == activity2.id))

          # `:effect` comes back as an atom on the list read path — this is
          # what `play_balance.ex` and the dashboard actually consume.
          assert Enum.find(activities, &(&1.id == activity1.id)).effect == :positive
          assert Enum.find(activities, &(&1.id == activity2.id)).effect == :negative
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

        test "update_activity/3 accepts %{effect: ...} on its own, leaving multiplier untouched", %{
          user_id: user_id
        } do
          {:ok, activity} =
            @persistence.create_activity(user_id, %{
              name: "Coding",
              time_source_identifier: "coding-proj-1",
              multiplier: 2.5
            })

          assert {:ok, drained} =
                   @persistence.update_activity(user_id, activity.id, %{effect: :negative})

          assert drained.effect == :negative
          assert drained.multiplier == 2.5

          assert {:ok, restored} =
                   @persistence.update_activity(user_id, activity.id, %{effect: :positive})

          assert restored.effect == :positive
          assert restored.multiplier == 2.5
        end

        test "update_activity/3 rejects a non-positive multiplier", %{user_id: user_id} do
          {:ok, activity} =
            @persistence.create_activity(user_id, %{
              name: "Coding",
              time_source_identifier: "coding-proj-1",
              multiplier: 1.0
            })

          assert {:error, _} = @persistence.update_activity(user_id, activity.id, %{multiplier: 0.0})
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

      describe "entry consumption (ADR-0012)" do
        test "list_entry_consumption/1 returns an empty list when nothing's been consumed", %{
          user_id: user_id
        } do
          assert {:ok, []} = @persistence.list_entry_consumption(user_id)
        end

        test "record_entry_consumption/4 creates a row and returns the cumulative total", %{
          user_id: user_id
        } do
          assert {:ok, 12.0} =
                   @persistence.record_entry_consumption(user_id, "activity-1", "entry-1", 12.0)

          assert {:ok, [row]} = @persistence.list_entry_consumption(user_id)
          assert row.activity_id == "activity-1"
          assert row.time_entry_id == "entry-1"
          assert row.consumed_minutes == 12.0
        end

        test "record_entry_consumption/4 adds to, rather than overwrites, an existing row for the same entry",
             %{user_id: user_id} do
          {:ok, _} = @persistence.record_entry_consumption(user_id, "activity-1", "entry-1", 12.0)

          assert {:ok, 20.0} =
                   @persistence.record_entry_consumption(user_id, "activity-1", "entry-1", 8.0)

          assert {:ok, [row]} = @persistence.list_entry_consumption(user_id)
          assert row.consumed_minutes == 20.0
        end

        test "record_entry_consumption/4 keeps separate entries on the same activity independent",
             %{user_id: user_id} do
          {:ok, _} = @persistence.record_entry_consumption(user_id, "activity-1", "entry-1", 12.0)
          {:ok, _} = @persistence.record_entry_consumption(user_id, "activity-1", "entry-2", 5.0)

          assert {:ok, rows} = @persistence.list_entry_consumption(user_id)
          assert length(rows) == 2

          assert Enum.find(rows, &(&1.time_entry_id == "entry-1")).consumed_minutes == 12.0
          assert Enum.find(rows, &(&1.time_entry_id == "entry-2")).consumed_minutes == 5.0
        end

        test "keeps the same {activity_id, time_entry_id} independent across two users", %{
          user_id: user_id,
          other_user_id: other_user_id
        } do
          {:ok, _} = @persistence.record_entry_consumption(user_id, "activity-1", "entry-1", 10.0)
          {:ok, _} = @persistence.record_entry_consumption(other_user_id, "activity-1", "entry-1", 999.0)

          assert {:ok, [row]} = @persistence.list_entry_consumption(user_id)
          assert row.consumed_minutes == 10.0

          assert {:ok, [other_row]} = @persistence.list_entry_consumption(other_user_id)
          assert other_row.consumed_minutes == 999.0
        end

        test "entry consumption is isolated per user", %{
          user_id: user_id,
          other_user_id: other_user_id
        } do
          {:ok, _} = @persistence.record_entry_consumption(other_user_id, "activity-1", "entry-1", 999.0)

          assert {:ok, []} = @persistence.list_entry_consumption(user_id)
        end
      end

      describe "record_entry_consumptions/2 (the backfill's atomic batch write)" do
        test "records every given row in one call", %{user_id: user_id} do
          consumptions = [
            %{activity_id: "activity-1", time_entry_id: "entry-1", minutes: 12.0},
            %{activity_id: "activity-2", time_entry_id: "entry-2", minutes: 3.0}
          ]

          assert {:ok, 2} = @persistence.record_entry_consumptions(user_id, consumptions)

          assert {:ok, rows} = @persistence.list_entry_consumption(user_id)
          assert Enum.find(rows, &(&1.time_entry_id == "entry-1")).consumed_minutes == 12.0
          assert Enum.find(rows, &(&1.time_entry_id == "entry-2")).consumed_minutes == 3.0
        end

        test "adds to, rather than overwrites, existing consumption on an entry", %{user_id: user_id} do
          {:ok, _} = @persistence.record_entry_consumption(user_id, "activity-1", "entry-1", 5.0)

          assert {:ok, 1} =
                   @persistence.record_entry_consumptions(user_id, [
                     %{activity_id: "activity-1", time_entry_id: "entry-1", minutes: 7.0}
                   ])

          assert {:ok, [row]} = @persistence.list_entry_consumption(user_id)
          assert row.consumed_minutes == 12.0
        end

        test "writes nothing at all when any row in the batch is invalid", %{user_id: user_id} do
          consumptions = [
            %{activity_id: "activity-1", time_entry_id: "entry-1", minutes: 12.0},
            %{activity_id: nil, time_entry_id: "entry-2", minutes: 3.0}
          ]

          assert {:error, _reason} =
                   @persistence.record_entry_consumptions(user_id, consumptions)

          # All-or-nothing: a half-seeded ledger would report a permanently
          # wrong deficit, and the backfill refuses to re-run over existing
          # rows (ADR-0012).
          assert {:ok, []} = @persistence.list_entry_consumption(user_id)
        end

        test "accepts an empty batch", %{user_id: user_id} do
          assert {:ok, 0} = @persistence.record_entry_consumptions(user_id, [])
        end
      end

      describe "record_spend/4 (ADR-0012's atomic write path)" do
        test "atomically records every consumption delta and logs the usage in one call", %{
          user_id: user_id
        } do
          consumptions = [
            %{activity_id: "activity-1", time_entry_id: "entry-1", minutes: 12.0},
            %{activity_id: "activity-1", time_entry_id: "entry-2", minutes: 3.0}
          ]

          logged_at = ~U[2024-01-15 10:30:00Z]

          assert {:ok, usage} = @persistence.record_spend(user_id, consumptions, 15.0, logged_at)
          assert usage.id
          assert usage.minutes == 15.0
          assert usage.logged_at == logged_at

          assert {:ok, rows} = @persistence.list_entry_consumption(user_id)
          assert Enum.find(rows, &(&1.time_entry_id == "entry-1")).consumed_minutes == 12.0
          assert Enum.find(rows, &(&1.time_entry_id == "entry-2")).consumed_minutes == 3.0

          assert {:ok, [logged]} = @persistence.list_playtime_used(user_id)
          assert logged.id == usage.id
        end

        test "adds to, rather than overwrites, existing consumption on an entry", %{user_id: user_id} do
          {:ok, _} = @persistence.record_entry_consumption(user_id, "activity-1", "entry-1", 5.0)

          assert {:ok, _usage} =
                   @persistence.record_spend(
                     user_id,
                     [%{activity_id: "activity-1", time_entry_id: "entry-1", minutes: 7.0}],
                     7.0,
                     DateTime.utc_now()
                   )

          assert {:ok, [row]} = @persistence.list_entry_consumption(user_id)
          assert row.consumed_minutes == 12.0
        end

        test "logs the usage even with an empty consumptions list (a fully unmatched, all-deficit spend)",
             %{user_id: user_id} do
          assert {:ok, usage} = @persistence.record_spend(user_id, [], 30.0, DateTime.utc_now())
          assert usage.minutes == 30.0
          assert {:ok, []} = @persistence.list_entry_consumption(user_id)
        end
      end
    end
  end
end
