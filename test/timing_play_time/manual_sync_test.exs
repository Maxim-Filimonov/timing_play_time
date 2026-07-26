defmodule TimingPlayTime.ManualSyncTest do
  # async: false — see comment in activity_manager_test.exs.
  use ExUnit.Case, async: false

  alias TimingPlayTime.ManualSync
  alias TimingPlayTime.Plugins.Persistence.Stub, as: PersistenceStub

  setup do
    :ok = PersistenceStub.clear_all_state()
    %{user_id: Ecto.UUID.generate()}
  end

  describe "get_total/1" do
    test "returns 0.0 when no manual sync has been set", %{user_id: user_id} do
      assert {:ok, 0.0} = ManualSync.get_total(user_id)
    end

    test "returns the current manual sync total", %{user_id: user_id} do
      {:ok, _} = PersistenceStub.set_manual_sync_total(user_id, 150.5)
      assert {:ok, 150.5} = ManualSync.get_total(user_id)
    end
  end

  describe "set_total/2" do
    test "sets the manual sync total", %{user_id: user_id} do
      assert {:ok, 250.0} = ManualSync.set_total(user_id, 250.0)
      assert {:ok, 250.0} = ManualSync.get_total(user_id)
    end

    test "overwrites previous manual sync total", %{user_id: user_id} do
      {:ok, _} = ManualSync.set_total(user_id, 100.0)
      assert {:ok, 100.0} = ManualSync.get_total(user_id)

      {:ok, _} = ManualSync.set_total(user_id, 200.0)
      assert {:ok, 200.0} = ManualSync.get_total(user_id)
    end

    test "accepts float values", %{user_id: user_id} do
      assert {:ok, 123.45} = ManualSync.set_total(user_id, 123.45)
      assert {:ok, 123.45} = ManualSync.get_total(user_id)
    end

    test "accepts zero", %{user_id: user_id} do
      {:ok, _} = ManualSync.set_total(user_id, 100.0)
      assert {:ok, 0.0} = ManualSync.set_total(user_id, 0.0)
      assert {:ok, 0.0} = ManualSync.get_total(user_id)
    end
  end
end
