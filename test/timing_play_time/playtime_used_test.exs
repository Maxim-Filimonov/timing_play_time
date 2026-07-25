defmodule TimingPlayTime.PlaytimeUsedTest do
  use ExUnit.Case, async: true

  alias TimingPlayTime.PlaytimeUsed
  alias TimingPlayTime.Plugins.Persistence.Stub, as: PersistenceStub

  describe "log_usage/1" do
    setup do
      :ok = PersistenceStub.clear_all_state()
      %{}
    end

    test "logs playtime usage with current timestamp" do
      assert {:ok, usage} = PlaytimeUsed.log_usage(30.0)
      assert usage.minutes == 30.0
      assert %DateTime{} = usage.logged_at
    end

    test "accepts float values" do
      assert {:ok, usage} = PlaytimeUsed.log_usage(45.5)
      assert usage.minutes == 45.5
    end
  end

  describe "log_usage/2" do
    setup do
      :ok = PersistenceStub.clear_all_state()
      %{}
    end

    test "logs playtime usage with custom timestamp" do
      custom_time = ~U[2024-01-15 10:30:00Z]
      assert {:ok, usage} = PlaytimeUsed.log_usage(20.0, custom_time)
      assert usage.minutes == 20.0
      assert usage.logged_at == custom_time
    end
  end

  describe "list_all/0" do
    setup do
      :ok = PersistenceStub.clear_all_state()
      %{}
    end

    test "returns empty list when no usage logged" do
      assert {:ok, []} = PlaytimeUsed.list_all()
    end

    test "returns all logged usage" do
      {:ok, _} = PlaytimeUsed.log_usage(10.0)
      {:ok, _} = PlaytimeUsed.log_usage(20.0)

      assert {:ok, usages} = PlaytimeUsed.list_all()
      assert length(usages) == 2
    end
  end

  describe "total_used/0" do
    setup do
      :ok = PersistenceStub.clear_all_state()
      %{}
    end

    test "returns 0.0 when no usage logged" do
      assert {:ok, total} = PlaytimeUsed.total_used()
      assert total == 0.0
    end

    test "returns sum of all logged usage" do
      {:ok, _} = PlaytimeUsed.log_usage(10.0)
      {:ok, _} = PlaytimeUsed.log_usage(25.5)
      {:ok, _} = PlaytimeUsed.log_usage(15.0)

      assert {:ok, total} = PlaytimeUsed.total_used()
      assert total == 50.5
    end
  end
end
