defmodule TimingPlayTime.Plugins.Persistence.StubTest do
  # async: false — see comment in activity_manager_test.exs.
  use ExUnit.Case, async: false

  use TimingPlayTime.PersistenceContractCase,
    adapter: TimingPlayTime.Plugins.Persistence.Stub,
    user_id_fixture: {TimingPlayTime.Support.Fixtures, :random_user_id},
    cleanup: {TimingPlayTime.Plugins.Persistence.Stub, :clear_all_state}
end
