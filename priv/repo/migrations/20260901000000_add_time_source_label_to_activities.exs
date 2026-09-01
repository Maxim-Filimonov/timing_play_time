defmodule TimingPlayTime.Repo.Migrations.AddTimeSourceLabelToActivities do
  @moduledoc """
  Adds the nullable `time_source_label` column (ADR-0014): the flattened
  Source path string (`"Edu → Coding"`) snapshotted when the user picks a
  Source in the Activity form. Never auto-refreshed — it records what was
  picked even if the upstream source is later renamed or deleted.

  Nullable, no backfill: existing Activities keep a `nil` label and the
  Activity card falls back to showing the bare `time_source_identifier`.
  Plain `change/0` — dropping a column is a clean reverse.
  """

  use Ecto.Migration

  def change do
    alter table(:activities) do
      add :time_source_label, :string, null: true
    end
  end
end
