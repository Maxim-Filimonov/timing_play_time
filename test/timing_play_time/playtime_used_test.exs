defmodule TimingPlayTime.PlaytimeUsedTest do
  # async: false — see comment in activity_manager_test.exs.
  use ExUnit.Case, async: false

  alias TimingPlayTime.PlaytimeUsed
  alias TimingPlayTime.Plugins.Persistence.Stub, as: PersistenceStub

  setup do
    :ok = PersistenceStub.clear_all_state()
    %{user_id: Ecto.UUID.generate()}
  end

  describe "log_usage/2" do
    test "logs playtime usage with current timestamp", %{user_id: user_id} do
      assert {:ok, usage} = PlaytimeUsed.log_usage(user_id, 30.0)
      assert usage.minutes == 30.0
      assert %DateTime{} = usage.logged_at
    end

    test "accepts float values", %{user_id: user_id} do
      assert {:ok, usage} = PlaytimeUsed.log_usage(user_id, 45.5)
      assert usage.minutes == 45.5
    end
  end

  describe "log_usage/3" do
    test "logs playtime usage with custom timestamp", %{user_id: user_id} do
      custom_time = ~U[2024-01-15 10:30:00Z]
      assert {:ok, usage} = PlaytimeUsed.log_usage(user_id, 20.0, custom_time)
      assert usage.minutes == 20.0
      assert usage.logged_at == custom_time
    end
  end

  describe "list_all/1" do
    test "returns empty list when no usage logged", %{user_id: user_id} do
      assert {:ok, []} = PlaytimeUsed.list_all(user_id)
    end

    test "returns all logged usage for that user", %{user_id: user_id} do
      {:ok, _} = PlaytimeUsed.log_usage(user_id, 10.0)
      {:ok, _} = PlaytimeUsed.log_usage(user_id, 20.0)

      assert {:ok, usages} = PlaytimeUsed.list_all(user_id)
      assert length(usages) == 2
    end
  end

  describe "total_used/1" do
    test "returns 0.0 when no usage logged", %{user_id: user_id} do
      assert {:ok, total} = PlaytimeUsed.total_used(user_id)
      assert total == 0.0
    end

    test "returns sum of all logged usage", %{user_id: user_id} do
      {:ok, _} = PlaytimeUsed.log_usage(user_id, 10.0)
      {:ok, _} = PlaytimeUsed.log_usage(user_id, 25.5)
      {:ok, _} = PlaytimeUsed.log_usage(user_id, 15.0)

      assert {:ok, total} = PlaytimeUsed.total_used(user_id)
      assert total == 50.5
    end
  end

  describe "total_used_today/3" do
    test "returns 0.0 when no usage logged today", %{user_id: user_id} do
      now = ~U[2026-07-25 10:00:00Z]

      assert {:ok, total} = PlaytimeUsed.total_used_today(user_id, "Pacific/Auckland", now)
      assert total == 0.0
    end

    test "excludes an entry from before local start-of-day, includes one after", %{
      user_id: user_id
    } do
      # Local (Pacific/Auckland, NZST/UTC+12) start of today is 2026-07-24T12:00:00Z.
      now = ~U[2026-07-25 10:00:00Z]

      {:ok, _} = PlaytimeUsed.log_usage(user_id, 999.0, ~U[2026-07-24 11:00:00Z])
      {:ok, _} = PlaytimeUsed.log_usage(user_id, 20.0, ~U[2026-07-24 12:00:00Z])
      {:ok, _} = PlaytimeUsed.log_usage(user_id, 5.5, ~U[2026-07-25 09:00:00Z])

      assert {:ok, total} = PlaytimeUsed.total_used_today(user_id, "Pacific/Auckland", now)
      assert total == 25.5
    end
  end

  describe "total_used_before_today/3" do
    test "returns 0.0 when no usage logged", %{user_id: user_id} do
      now = ~U[2026-07-25 10:00:00Z]

      assert {:ok, total} = PlaytimeUsed.total_used_before_today(user_id, "Pacific/Auckland", now)
      assert total == 0.0
    end

    test "includes an entry from before local start-of-day, excludes one from today", %{
      user_id: user_id
    } do
      # Local (Pacific/Auckland, NZST/UTC+12) start of today is 2026-07-24T12:00:00Z.
      now = ~U[2026-07-25 10:00:00Z]

      {:ok, _} = PlaytimeUsed.log_usage(user_id, 999.0, ~U[2026-07-24 11:00:00Z])
      {:ok, _} = PlaytimeUsed.log_usage(user_id, 20.0, ~U[2026-07-24 12:00:00Z])
      {:ok, _} = PlaytimeUsed.log_usage(user_id, 5.5, ~U[2026-07-25 09:00:00Z])

      assert {:ok, total} = PlaytimeUsed.total_used_before_today(user_id, "Pacific/Auckland", now)
      assert total == 999.0
    end
  end
end
