defmodule TimingPlayTime.Repo.Migrations.AddUserIdToExistingTables do
  @moduledoc """
  Scopes `activities`, `manual_syncs`, and `playtime_used` to a `user_id`
  (ADR-0006). Existing rows are backfilled onto one default User, created
  here, so pre-multi-tenancy data survives the migration.
  """

  use Ecto.Migration

  # Minimal migration-local schemas (rather than raw SQL) so binary_id
  # values round-trip through Ecto's normal dump/load, regardless of how the
  # SQLite adapter represents them on disk.
  defmodule MigrationUser do
    use Ecto.Schema
    @primary_key {:id, :binary_id, autogenerate: true}
    schema "users" do
      field :timezone, :string
      Ecto.Schema.timestamps(type: :utc_datetime)
    end
  end

  defmodule MigrationActivity do
    use Ecto.Schema
    @primary_key {:id, :binary_id, autogenerate: true}
    schema "activities" do
      field :user_id, :binary_id
    end
  end

  defmodule MigrationManualSync do
    use Ecto.Schema
    @primary_key {:id, :binary_id, autogenerate: true}
    schema "manual_syncs" do
      field :user_id, :binary_id
    end
  end

  defmodule MigrationPlaytimeUsed do
    use Ecto.Schema
    @primary_key {:id, :binary_id, autogenerate: true}
    schema "playtime_used" do
      field :user_id, :binary_id
    end
  end

  def up do
    alter table(:activities) do
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all)
    end

    alter table(:manual_syncs) do
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all)
    end

    alter table(:playtime_used) do
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all)
    end

    flush()

    default_user = repo().insert!(%MigrationUser{})

    repo().update_all(MigrationActivity, set: [user_id: default_user.id])
    repo().update_all(MigrationManualSync, set: [user_id: default_user.id])
    repo().update_all(MigrationPlaytimeUsed, set: [user_id: default_user.id])

    # SQLite doesn't support ALTER COLUMN, so `user_id` stays nullable at the
    # schema level (every existing row is backfilled above); presence for new
    # rows is enforced by the Ecto schemas' changesets instead.
    create index(:activities, [:user_id])
    create index(:manual_syncs, [:user_id])
    create index(:playtime_used, [:user_id])

    IO.puts("""

    Backfilled existing Activities/Manual Syncs/Playtime Used onto default user:
      #{default_user.id}

    To use the existing data from your browser, this id needs to end up in your
    session cookie — the one-time manual linking step from ADR-0006.
    """)
  end

  def down do
    drop index(:activities, [:user_id])
    drop index(:manual_syncs, [:user_id])
    drop index(:playtime_used, [:user_id])

    alter table(:activities) do
      remove :user_id
    end

    alter table(:manual_syncs) do
      remove :user_id
    end

    alter table(:playtime_used) do
      remove :user_id
    end
  end
end
