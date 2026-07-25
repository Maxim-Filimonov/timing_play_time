defmodule TimingPlayTime.Plugins.Persistence.SqliteTest do
  use TimingPlayTime.DataCase, async: false

  use TimingPlayTime.PersistenceContractCase,
    adapter: TimingPlayTime.Plugins.Persistence.Sqlite
end
