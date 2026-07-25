defmodule TimingPlayTime.Plugins.Persistence.StubTest do
  use ExUnit.Case, async: true

  use TimingPlayTime.PersistenceContractCase,
    adapter: TimingPlayTime.Plugins.Persistence.Stub,
    cleanup: {TimingPlayTime.Plugins.Persistence.Stub, :clear_all_state}
end
