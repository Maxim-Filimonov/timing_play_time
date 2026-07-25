defmodule TimingPlayTime.Repo.Migrations.CreatePlaytimeUsed do
  use Ecto.Migration

  def change do
    create table(:playtime_used, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :minutes, :float, null: false
      add :logged_at, :utc_datetime, null: false

      timestamps(type: :utc_datetime)
    end
  end
end
