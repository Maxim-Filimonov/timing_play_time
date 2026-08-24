defmodule Mix.Tasks.Balance.BackfillConsumptionTest do
  # async: false — exercises the globally-named Persistence.Stub GenServer,
  # same as the other Stub-backed suites.
  use TimingPlayTime.DataCase, async: false

  alias TimingPlayTime.Accounts
  alias TimingPlayTime.PlaytimeUsed
  alias TimingPlayTime.Plugins.Persistence.Stub, as: PersistenceStub

  setup do
    :ok = PersistenceStub.clear_all_state()
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(Mix.Shell.IO) end)

    {:ok, user} = Accounts.create_user()
    {:ok, user} = Accounts.update_timezone(user, "Pacific/Auckland")

    %{user: user}
  end

  defp seed_activity_and_usage(user) do
    {:ok, activity} =
      PersistenceStub.create_activity(user.id, %{
        name: "Coding",
        time_source_identifier: "coding-proj-1",
        multiplier: 1.0,
        activated_at: DateTime.add(DateTime.utc_now(), -3, :day)
      })

    {:ok, _usage} = PlaytimeUsed.log_usage(user.id, 30.0)

    activity
  end

  test "seeds the ledger with what history actually consumed", %{user: user} do
    activity = seed_activity_and_usage(user)

    Mix.Tasks.Balance.BackfillConsumption.run(["--user-id", user.id])

    assert {:ok, rows} = PersistenceStub.list_entry_consumption(user.id)
    assert rows != []
    assert Enum.all?(rows, &(&1.activity_id == activity.id))
    # The ledger's time_entry_id column is a :string — anything else fails
    # to persist and never matches on a later read (ADR-0012).
    assert Enum.all?(rows, &is_binary(&1.time_entry_id))
    assert Enum.reduce(rows, 0.0, &(&2 + &1.consumed_minutes)) == 30.0
  end

  test "raises rather than exiting quietly when a lookup fails", %{user: user} do
    seed_activity_and_usage(user)
    PersistenceStub.fail_list_activities({:error, :boom})
    on_exit(fn -> PersistenceStub.fail_list_activities(nil) end)

    assert_raise Mix.Error, fn ->
      Mix.Tasks.Balance.BackfillConsumption.run(["--user-id", user.id])
    end

    assert {:ok, []} = PersistenceStub.list_entry_consumption(user.id)
  end

  test "refuses to run against a User who already has consumption rows", %{user: user} do
    seed_activity_and_usage(user)
    {:ok, _} = PersistenceStub.record_entry_consumption(user.id, "activity-1", "entry-1", 5.0)

    assert_raise Mix.Error, fn ->
      Mix.Tasks.Balance.BackfillConsumption.run(["--user-id", user.id])
    end
  end
end
