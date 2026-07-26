defmodule TimingPlayTime.Plugins.Persistence.Sqlite.Activity do
  @moduledoc false

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "activities" do
    field :name, :string
    field :time_source_identifier, :string
    field :multiplier, :float
    field :activated_at, :utc_datetime
    field :user_id, :binary_id

    timestamps(type: :utc_datetime)
  end

  @fields [:name, :time_source_identifier, :multiplier, :activated_at, :user_id]

  def changeset(activity, attrs) do
    activity
    |> cast(attrs, @fields)
    |> put_default_activated_at()
    |> validate_required(@fields)
  end

  defp put_default_activated_at(changeset) do
    case get_field(changeset, :activated_at) do
      nil -> put_change(changeset, :activated_at, DateTime.utc_now() |> DateTime.truncate(:second))
      _ -> changeset
    end
  end
end
