defmodule TimingPlayTime.ActivityManagerTest do
  # async: false — TimingPlayTime.Plugins.Persistence.Stub is a single
  # globally-named GenServer shared by every test in the process;
  # clear_all_state/0 racing against other async Stub-backed test modules
  # causes intermittent cross-test data wipes.
  use ExUnit.Case, async: false

  alias TimingPlayTime.ActivityManager
  alias TimingPlayTime.Plugins.Persistence.Stub, as: PersistenceStub

  setup do
    :ok = PersistenceStub.clear_all_state()
    %{user_id: Ecto.UUID.generate()}
  end

  describe "list_activities/1" do
    test "returns empty list when no activities exist", %{user_id: user_id} do
      assert {:ok, []} = ActivityManager.list_activities(user_id)
    end

    test "returns all activities for that user", %{user_id: user_id} do
      {:ok, activity1} =
        PersistenceStub.create_activity(user_id, %{
          name: "Coding",
          time_source_identifier: "coding-proj-1",
          multiplier: 1.5,
          activated_at: DateTime.utc_now()
        })

      {:ok, activity2} =
        PersistenceStub.create_activity(user_id, %{
          name: "Learning",
          time_source_identifier: "learning-proj-1",
          multiplier: 2.0,
          activated_at: DateTime.utc_now()
        })

      assert {:ok, activities} = ActivityManager.list_activities(user_id)
      assert length(activities) == 2
      assert Enum.any?(activities, &(&1.id == activity1.id))
      assert Enum.any?(activities, &(&1.id == activity2.id))
    end

    test "does not include another user's activities", %{user_id: user_id} do
      {:ok, _mine} =
        PersistenceStub.create_activity(user_id, %{
          name: "Mine",
          time_source_identifier: "mine-proj",
          multiplier: 1.0,
          activated_at: DateTime.utc_now()
        })

      {:ok, _theirs} =
        PersistenceStub.create_activity(Ecto.UUID.generate(), %{
          name: "Theirs",
          time_source_identifier: "theirs-proj",
          multiplier: 1.0,
          activated_at: DateTime.utc_now()
        })

      assert {:ok, [%{name: "Mine"}]} = ActivityManager.list_activities(user_id)
    end
  end

  describe "get_activity/2" do
    test "returns activity when it exists", %{user_id: user_id} do
      {:ok, created} =
        PersistenceStub.create_activity(user_id, %{
          name: "Exercise",
          time_source_identifier: "exercise-proj-1",
          multiplier: 1.0,
          activated_at: DateTime.utc_now()
        })

      assert {:ok, activity} = ActivityManager.get_activity(user_id, created.id)
      assert activity.id == created.id
      assert activity.name == "Exercise"
    end

    test "returns error when activity doesn't exist", %{user_id: user_id} do
      assert {:error, :not_found} = ActivityManager.get_activity(user_id, "nonexistent-id")
    end
  end

  describe "create_activity/2" do
    test "creates activity with valid attrs", %{user_id: user_id} do
      attrs = %{
        name: "Writing",
        time_source_identifier: "writing-proj-1",
        multiplier: 1.2,
        activated_at: DateTime.utc_now()
      }

      assert {:ok, activity} = ActivityManager.create_activity(user_id, attrs)
      assert activity.name == "Writing"
      assert activity.multiplier == 1.2
      assert activity.time_source_identifier == "writing-proj-1"
    end

    test "defaults activated_at to current time when not provided", %{user_id: user_id} do
      attrs = %{
        name: "Reading",
        time_source_identifier: "reading-proj-1",
        multiplier: 1.0
      }

      before = DateTime.utc_now()
      assert {:ok, activity} = ActivityManager.create_activity(user_id, attrs)
      after_time = DateTime.utc_now()

      assert DateTime.compare(activity.activated_at, before) in [:gt, :eq]
      assert DateTime.compare(activity.activated_at, after_time) in [:lt, :eq]
    end
  end

  describe "update_activity/3" do
    setup %{user_id: user_id} do
      {:ok, activity} =
        PersistenceStub.create_activity(user_id, %{
          name: "Original",
          time_source_identifier: "original-proj",
          multiplier: 1.0,
          activated_at: DateTime.utc_now()
        })

      %{activity: activity}
    end

    test "updates activity with new attrs", %{user_id: user_id, activity: activity} do
      assert {:ok, updated} =
               ActivityManager.update_activity(user_id, activity.id, %{
                 name: "Updated",
                 multiplier: 2.5
               })

      assert updated.id == activity.id
      assert updated.name == "Updated"
      assert updated.multiplier == 2.5
    end

    test "returns error when activity doesn't exist", %{user_id: user_id} do
      assert {:error, :not_found} =
               ActivityManager.update_activity(user_id, "nonexistent", %{name: "Fail"})
    end
  end

  describe "delete_activity/2" do
    setup %{user_id: user_id} do
      {:ok, activity} =
        PersistenceStub.create_activity(user_id, %{
          name: "ToDelete",
          time_source_identifier: "delete-proj",
          multiplier: 1.0,
          activated_at: DateTime.utc_now()
        })

      %{activity: activity}
    end

    test "deletes existing activity", %{user_id: user_id, activity: activity} do
      assert :ok = ActivityManager.delete_activity(user_id, activity.id)
      assert {:error, :not_found} = ActivityManager.get_activity(user_id, activity.id)
    end

    test "returns ok even when activity doesn't exist", %{user_id: user_id} do
      assert :ok = ActivityManager.delete_activity(user_id, "nonexistent-id")
    end
  end
end
