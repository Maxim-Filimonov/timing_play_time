defmodule TimingPlayTime.Repo.Migrations.CreateManualSyncs do
  use Ecto.Migration

  def change do
    create table(:manual_syncs, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :minutes, :float, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create index(:manual_syncs, [:inserted_at])
  end
end
