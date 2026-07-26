defmodule TimingPlayTime.Repo.Migrations.CreateIntegrations do
  use Ecto.Migration

  def change do
    create table(:integrations, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :provider, :string, null: false
      # Encrypted map (ADR-0007) — each provider adapter owns interpretation
      # of its own shape (e.g. Timing stores %{"api_key" => "..."}).
      add :credentials, :binary, null: false

      timestamps(type: :utc_datetime)
    end

    # One Integration per User at a time (ADR-0007) — not a multi-row model
    # with an `active` flag.
    create unique_index(:integrations, [:user_id])
  end
end
