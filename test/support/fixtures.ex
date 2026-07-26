defmodule TimingPlayTime.Support.Fixtures do
  @moduledoc false

  alias TimingPlayTime.Accounts

  @doc "A real, DB-persisted User id — required by adapters (Sqlite) that enforce the user_id foreign key."
  def persisted_user_id do
    {:ok, user} = Accounts.create_user()
    user.id
  end

  @doc "An opaque user id with no backing row — sufficient for adapters (Stub) with no referential integrity."
  def random_user_id do
    Ecto.UUID.generate()
  end
end
