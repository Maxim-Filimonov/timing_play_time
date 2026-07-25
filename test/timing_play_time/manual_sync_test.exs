defmodule TimingPlayTime.ManualSyncTest do
  use ExUnit.Case, async: true

  alias TimingPlayTime.ManualSync
  alias TimingPlayTime.Plugins.Persistence.Stub, as: PersistenceStub

  describe "get_total/0" do
    setup do
      :ok = PersistenceStub.clear_all_state()
      %{}
    end

    test "returns 0.0 when no manual sync has been set" do
      assert {:ok, 0.0} = ManualSync.get_total()
    end

    test "returns the current manual sync total" do
      {:ok, _} = PersistenceStub.set_manual_sync_total(150.5)
      assert {:ok, 150.5} = ManualSync.get_total()
    end
  end

  describe "set_total/1" do
    setup do
      :ok = PersistenceStub.clear_all_state()
      %{}
    end

    test "sets the manual sync total" do
      assert {:ok, 250.0} = ManualSync.set_total(250.0)
      assert {:ok, 250.0} = ManualSync.get_total()
    end

    test "overwrites previous manual sync total" do
      {:ok, _} = ManualSync.set_total(100.0)
      assert {:ok, 100.0} = ManualSync.get_total()

      {:ok, _} = ManualSync.set_total(200.0)
      assert {:ok, 200.0} = ManualSync.get_total()
    end

    test "accepts float values" do
      assert {:ok, 123.45} = ManualSync.set_total(123.45)
      assert {:ok, 123.45} = ManualSync.get_total()
    end

    test "accepts zero" do
      {:ok, _} = ManualSync.set_total(100.0)
      assert {:ok, 0.0} = ManualSync.set_total(0.0)
      assert {:ok, 0.0} = ManualSync.get_total()
    end
  end
end
