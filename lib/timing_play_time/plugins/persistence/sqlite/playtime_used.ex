defmodule TimingPlayTime.Plugins.Persistence.Sqlite.PlaytimeUsed do
  @moduledoc false

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "playtime_used" do
    field :minutes, :float
    field :logged_at, :utc_datetime
    field :user_id, :binary_id

    timestamps(type: :utc_datetime)
  end

  def changeset(playtime_used, attrs) do
    playtime_used
    |> cast(attrs, [:minutes, :logged_at, :user_id])
    |> validate_required([:minutes, :logged_at, :user_id])
  end
end
