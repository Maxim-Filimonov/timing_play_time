defmodule TimingPlayTime.ActivityManagerTest do
  use ExUnit.Case, async: true

  alias TimingPlayTime.ActivityManager
  alias TimingPlayTime.Plugins.Persistence.Stub, as: PersistenceStub

  describe "list_activities/0" do
    setup do
      # Clear any existing state for test isolation
      :ok = PersistenceStub.clear_all_state()
      %{}
    end

    test "returns empty list when no activities exist" do
      assert {:ok, []} = ActivityManager.list_activities()
    end

    test "returns all activities" do
      {:ok, activity1} =
        PersistenceStub.create_activity(%{
          name: "Coding",
          time_source_identifier: "coding-proj-1",
          multiplier: 1.5,
          activated_at: DateTime.utc_now()
        })

      {:ok, activity2} =
        PersistenceStub.create_activity(%{
          name: "Learning",
          time_source_identifier: "learning-proj-1",
          multiplier: 2.0,
          activated_at: DateTime.utc_now()
        })

      assert {:ok, activities} = ActivityManager.list_activities()
      assert length(activities) == 2
      assert Enum.any?(activities, &(&1.id == activity1.id))
      assert Enum.any?(activities, &(&1.id == activity2.id))
    end
  end

  describe "get_activity/1" do
    setup do
      :ok = PersistenceStub.clear_all_state()
      %{}
    end

    test "returns activity when it exists" do
      {:ok, created} =
        PersistenceStub.create_activity(%{
          name: "Exercise",
          time_source_identifier: "exercise-proj-1",
          multiplier: 1.0,
          activated_at: DateTime.utc_now()
        })

      assert {:ok, activity} = ActivityManager.get_activity(created.id)
      assert activity.id == created.id
      assert activity.name == "Exercise"
    end

    test "returns error when activity doesn't exist" do
      assert {:error, :not_found} = ActivityManager.get_activity("nonexistent-id")
    end
  end

  describe "create_activity/1" do
    setup do
      :ok = PersistenceStub.clear_all_state()
      %{}
    end

    test "creates activity with valid attrs" do
      attrs = %{
        name: "Writing",
        time_source_identifier: "writing-proj-1",
        multiplier: 1.2,
        activated_at: DateTime.utc_now()
      }

      assert {:ok, activity} = ActivityManager.create_activity(attrs)
      assert activity.name == "Writing"
      assert activity.multiplier == 1.2
      assert activity.time_source_identifier == "writing-proj-1"
    end

    test "defaults activated_at to current time when not provided" do
      attrs = %{
        name: "Reading",
        time_source_identifier: "reading-proj-1",
        multiplier: 1.0
      }

      before = DateTime.utc_now()
      assert {:ok, activity} = ActivityManager.create_activity(attrs)
      after_time = DateTime.utc_now()

      assert DateTime.compare(activity.activated_at, before) in [:gt, :eq]
      assert DateTime.compare(activity.activated_at, after_time) in [:lt, :eq]
    end
  end

  describe "update_activity/2" do
    setup do
      :ok = PersistenceStub.clear_all_state()

      {:ok, activity} =
        PersistenceStub.create_activity(%{
          name: "Original",
          time_source_identifier: "original-proj",
          multiplier: 1.0,
          activated_at: DateTime.utc_now()
        })

      %{activity: activity}
    end

    test "updates activity with new attrs", %{activity: activity} do
      assert {:ok, updated} =
               ActivityManager.update_activity(activity.id, %{
                 name: "Updated",
                 multiplier: 2.5
               })

      assert updated.id == activity.id
      assert updated.name == "Updated"
      assert updated.multiplier == 2.5
    end

    test "returns error when activity doesn't exist" do
      assert {:error, :not_found} =
               ActivityManager.update_activity("nonexistent", %{name: "Fail"})
    end
  end

  describe "delete_activity/1" do
    setup do
      :ok = PersistenceStub.clear_all_state()

      {:ok, activity} =
        PersistenceStub.create_activity(%{
          name: "ToDelete",
          time_source_identifier: "delete-proj",
          multiplier: 1.0,
          activated_at: DateTime.utc_now()
        })

      %{activity: activity}
    end

    test "deletes existing activity", %{activity: activity} do
      assert :ok = ActivityManager.delete_activity(activity.id)
      assert {:error, :not_found} = ActivityManager.get_activity(activity.id)
    end

    test "returns ok even when activity doesn't exist" do
      assert :ok = ActivityManager.delete_activity("nonexistent-id")
    end
  end
end
