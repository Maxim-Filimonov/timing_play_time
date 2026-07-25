defmodule TimingPlayTime.PlayBalanceTest do
  use ExUnit.Case, async: true

  alias TimingPlayTime.PlayBalance
  alias TimingPlayTime.Plugins.Persistence.Stub, as: PersistenceStub

  describe "compute/0" do
    setup do
      # Clear any existing state for test isolation
      :ok = PersistenceStub.clear_all_state()
      %{}
    end

    test "returns zero balance when no activities, manual sync, or playtime used" do
      assert {:ok, balance} = PlayBalance.compute()
      assert balance.total == 0.0
      assert balance.timing_derived_total == 0.0
      assert balance.manual_sync_total == 0.0
      assert balance.playtime_used_total == 0.0
    end

    test "calculates timing-derived total from active activities" do
      # Create activities with different multipliers
      {:ok, _activity1} =
        PersistenceStub.create_activity(%{
          name: "Coding",
          time_source_identifier: "coding-proj-1",
          multiplier: 1.5,
          activated_at: DateTime.add(DateTime.utc_now(), -7, :day)
        })

      {:ok, _activity2} =
        PersistenceStub.create_activity(%{
          name: "Learning",
          time_source_identifier: "learning-proj-1",
          multiplier: 2.0,
          activated_at: DateTime.add(DateTime.utc_now(), -3, :day)
        })

      # Stub returns: coding ~45min/day * 7 days = 315, learning ~42min/day * 3 days = 126
      # With multipliers: 315 * 1.5 = 472.5, 126 * 2.0 = 252
      # Total timing-derived = 724.5

      assert {:ok, balance} = PlayBalance.compute()
      assert_in_delta balance.timing_derived_total, 724.5, 0.1
      assert balance.manual_sync_total == 0.0
      assert balance.playtime_used_total == 0.0
      assert_in_delta balance.total, 724.5, 0.1
    end

    test "includes manual sync total in balance" do
      {:ok, _} = PersistenceStub.set_manual_sync_total(150.0)

      assert {:ok, balance} = PlayBalance.compute()
      assert balance.manual_sync_total == 150.0
      assert_in_delta balance.total, 150.0, 0.1
    end

    test "subtracts playtime used from balance" do
      # Log some playtime usage
      {:ok, _} = PersistenceStub.log_playtime_used(30.0, DateTime.utc_now())
      {:ok, _} = PersistenceStub.log_playtime_used(15.0, DateTime.utc_now())

      assert {:ok, balance} = PlayBalance.compute()
      assert balance.playtime_used_total == 45.0
      assert_in_delta balance.total, -45.0, 0.1
    end

    test "computes full balance with all components" do
      # Create activity
      {:ok, _activity} =
        PersistenceStub.create_activity(%{
          name: "Exercise",
          time_source_identifier: "exercise-proj-1",
          multiplier: 1.0,
          activated_at: DateTime.add(DateTime.utc_now(), -5, :day)
        })

      # Set manual sync
      {:ok, _} = PersistenceStub.set_manual_sync_total(100.0)

      # Log playtime used
      {:ok, _} = PersistenceStub.log_playtime_used(25.0, DateTime.utc_now())
      {:ok, _} = PersistenceStub.log_playtime_used(10.0, DateTime.utc_now())

      # Stub returns: exercise ~36min/day * 5 days = 180
      # With multiplier: 180 * 1.0 = 180
      # Balance = 180 (timing) + 100 (manual) - 35 (used) = 245

      assert {:ok, balance} = PlayBalance.compute()
      assert_in_delta balance.timing_derived_total, 180.0, 0.1
      assert balance.manual_sync_total == 100.0
      assert balance.playtime_used_total == 35.0
      assert_in_delta balance.total, 245.0, 0.1
    end

    test "handles negative balance when playtime used exceeds earned" do
      {:ok, _} = PersistenceStub.set_manual_sync_total(50.0)
      {:ok, _} = PersistenceStub.log_playtime_used(80.0, DateTime.utc_now())

      assert {:ok, balance} = PlayBalance.compute()
      assert_in_delta balance.total, -30.0, 0.1
    end
  end

  describe "today_activity_minutes/2" do
    setup do
      :ok = PersistenceStub.clear_all_state()
      %{}
    end

    test "clamps to the local start-of-day when the activity was activated on an earlier day" do
      {:ok, activity} =
        PersistenceStub.create_activity(%{
          name: "Coding",
          time_source_identifier: "coding-proj-1",
          multiplier: 2.0,
          activated_at: ~U[2026-07-20 00:00:00Z]
        })

      # Local (Pacific/Auckland, NZST/UTC+12) start of today is 2026-07-24T12:00:00Z;
      # `now` is 22h later, so elapsed today = 22/24 days.
      now = ~U[2026-07-25 10:00:00Z]

      assert {:ok, %{minutes: minutes, play_minutes: play_minutes}} =
               PlayBalance.today_activity_minutes(activity, now)

      assert_in_delta minutes, 45.0 * (22 / 24), 0.01
      assert_in_delta play_minutes, minutes * 2.0, 0.001
    end

    test "clamps to activated_at when the activity was activated later today" do
      {:ok, activity} =
        PersistenceStub.create_activity(%{
          name: "Learning",
          time_source_identifier: "learning-proj-1",
          multiplier: 1.0,
          # After local start-of-today (2026-07-24T12:00:00Z) but before `now`.
          activated_at: ~U[2026-07-25 01:00:00Z]
        })

      now = ~U[2026-07-25 10:00:00Z]

      assert {:ok, %{minutes: minutes, play_minutes: play_minutes}} =
               PlayBalance.today_activity_minutes(activity, now)

      assert_in_delta minutes, 42.0 * (9 / 24), 0.01
      assert_in_delta play_minutes, minutes, 0.001
    end
  end
end
