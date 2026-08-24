defmodule TimingPlayTime.Repo.Migrations.CreateEntryConsumptions do
  @moduledoc """
  The persisted Entry Consumption Ledger (ADR-0012): one row per Timing
  entry actually drawn on by a spend, holding cumulative consumed Play
  Minutes. Sparse — an entry nobody's spent against has no row.
  """

  use Ecto.Migration

  def change do
    create table(:entry_consumptions, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      # Not a real FK — activity_id/time_entry_id form a caller-supplied
      # identity pair from the Persistence behaviour's own contract, not
      # Ecto associations (mirrors activity_id elsewhere in this ledger,
      # e.g. EntryLedger.entry/0, which is always a plain id, never a
      # loaded association).
      add :activity_id, :string, null: false
      add :time_entry_id, :string, null: false
      add :consumed_minutes, :float, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:entry_consumptions, [:activity_id, :time_entry_id])
    create index(:entry_consumptions, [:user_id])
  end
end
