defmodule TimingPlayTime.Repo.Migrations.CreateUsers do
  use Ecto.Migration

  def change do
    create table(:users, primary_key: false) do
      add :id, :binary_id, primary_key: true
      # Nil until the first-visit browser Intl detection hook reports one
      # (ADR-0006) — no onboarding gate, no silent UTC default.
      add :timezone, :string

      timestamps(type: :utc_datetime)
    end
  end
end
