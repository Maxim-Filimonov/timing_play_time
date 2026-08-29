defmodule TimingPlayTime.Repo.Migrations.AddEffectToActivities do
  @moduledoc """
  Makes an Activity's Effect a stored column (ADR-0013). `multiplier`
  becomes an unsigned magnitude and the new `effect` column
  (`"positive"` / `"negative"`) carries the direction.

  `up`/`down`, not `change` — the backfill is not auto-reversible.

  The `multiplier > 0` invariant is enforced in the changeset
  (`Sqlite.Activity`) and in the Stub, not as a DB CHECK constraint:
  SQLite has no `ALTER TABLE ADD CONSTRAINT`, and a full table rebuild
  just for the belt-and-braces DB copy of a guard the write path already
  applies isn't worth the risk on a hand-run migration.
  """

  use Ecto.Migration

  def up do
    alter table(:activities) do
      add :effect, :string, null: false, default: "positive"
    end

    # Backfill + un-sign multiplier. Safe on any current data; also cleans
    # up any negative row that slipped through the currently-unvalidated
    # add form.
    execute """
    UPDATE activities
    SET effect = CASE WHEN multiplier < 0 THEN 'negative' ELSE 'positive' END,
        multiplier = abs(multiplier)
    """
  end

  def down do
    execute "UPDATE activities SET multiplier = -multiplier WHERE effect = 'negative'"

    alter table(:activities) do
      remove :effect
    end
  end
end
