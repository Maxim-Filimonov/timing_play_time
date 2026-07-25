defmodule TimingPlayTime.Repo.Migrations.CreateActivities do
  use Ecto.Migration

  def change do
    create table(:activities, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :time_source_identifier, :string, null: false
      add :multiplier, :float, null: false
      add :activated_at, :utc_datetime, null: false

      timestamps(type: :utc_datetime)
    end
  end
end
