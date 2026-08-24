defmodule TimingPlayTime.Plugins.Persistence.Sqlite.EntryConsumption do
  @moduledoc false

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "entry_consumptions" do
    field :activity_id, :string
    field :time_entry_id, :string
    field :consumed_minutes, :float
    field :user_id, :binary_id

    timestamps(type: :utc_datetime)
  end

  @fields [:activity_id, :time_entry_id, :consumed_minutes, :user_id]

  def changeset(entry_consumption, attrs) do
    entry_consumption
    |> cast(attrs, @fields)
    |> validate_required(@fields)
    |> unique_constraint([:user_id, :activity_id, :time_entry_id])
  end
end
