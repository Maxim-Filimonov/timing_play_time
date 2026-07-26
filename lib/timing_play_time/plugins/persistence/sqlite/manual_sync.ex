defmodule TimingPlayTime.Plugins.Persistence.Sqlite.ManualSync do
  @moduledoc false

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "manual_syncs" do
    field :minutes, :float
    field :user_id, :binary_id

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(manual_sync, attrs) do
    manual_sync
    |> cast(attrs, [:minutes, :user_id])
    |> validate_required([:minutes, :user_id])
  end
end
