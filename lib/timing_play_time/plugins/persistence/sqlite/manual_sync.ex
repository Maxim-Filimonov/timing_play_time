defmodule TimingPlayTime.Plugins.Persistence.Sqlite.ManualSync do
  @moduledoc false

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "manual_syncs" do
    field :minutes, :float

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(manual_sync, attrs) do
    manual_sync
    |> cast(attrs, [:minutes])
    |> validate_required([:minutes])
  end
end
