defmodule TimingPlayTime.Repo.Migrations.ScopeEntryConsumptionUniquenessToUser do
  @moduledoc """
  The Entry Consumption Ledger's identity is per-User (ADR-0006's tenant
  boundary): `{user_id, activity_id, time_entry_id}`, matching the Stub
  adapter's own key. Without `user_id` in the unique index, one User's
  upsert-increment lands on another User's row for the same
  activity/entry pair — silently attributing their consumption to someone
  else.
  """

  use Ecto.Migration

  def change do
    drop unique_index(:entry_consumptions, [:activity_id, :time_entry_id])
    create unique_index(:entry_consumptions, [:user_id, :activity_id, :time_entry_id])
  end
end
