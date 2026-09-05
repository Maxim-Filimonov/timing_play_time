defmodule TimingPlayTime.Repo.Migrations.AddAuth0IdentityToUsers do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :auth0_sub, :string
      add :email, :string
      add :arrival_banner_dismissed, :boolean, null: false, default: false
    end

    create unique_index(:users, [:auth0_sub])
    create unique_index(:users, [:email])
  end
end
