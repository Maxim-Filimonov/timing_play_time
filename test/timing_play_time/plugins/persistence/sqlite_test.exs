defmodule TimingPlayTime.Plugins.Persistence.SqliteTest do
  use TimingPlayTime.DataCase, async: false

  use TimingPlayTime.PersistenceContractCase,
    adapter: TimingPlayTime.Plugins.Persistence.Sqlite,
    user_id_fixture: {TimingPlayTime.Support.Fixtures, :persisted_user_id}
end
