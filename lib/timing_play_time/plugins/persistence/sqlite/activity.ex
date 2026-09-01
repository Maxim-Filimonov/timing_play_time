defmodule TimingPlayTime.Plugins.Persistence.Sqlite.Activity do
  @moduledoc false

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "activities" do
    field :name, :string
    field :time_source_identifier, :string
    field :time_source_label, :string
    field :multiplier, :float
    field :effect, Ecto.Enum, values: [:positive, :negative], default: :positive
    field :activated_at, :utc_datetime
    field :user_id, :binary_id

    timestamps(type: :utc_datetime)
  end

  # `:effect` is cast but kept out of `@required` — it's optional on create
  # (the DB default and the schema default cover it) and independently
  # updatable (ADR-0013 / #10). `Ecto.Enum` casts the `"positive"` /
  # `"negative"` string (or atom) to the atom and adds a changeset error for
  # anything else, for free.
  @required [:name, :time_source_identifier, :multiplier, :activated_at, :user_id]
  @optional [:effect, :time_source_label]

  def changeset(activity, attrs) do
    activity
    |> cast(attrs, @required ++ @optional)
    |> put_default_activated_at()
    |> validate_required(@required)
    |> validate_number(:multiplier, greater_than: 0)
  end

  defp put_default_activated_at(changeset) do
    case get_field(changeset, :activated_at) do
      nil -> put_change(changeset, :activated_at, DateTime.utc_now() |> DateTime.truncate(:second))
      _ -> changeset
    end
  end
end
