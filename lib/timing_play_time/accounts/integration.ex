defmodule TimingPlayTime.Accounts.Integration do
  @moduledoc """
  A User's connection to one external time-tracking provider at a time
  (ADR-0007). `credentials` is a single encrypted map whose shape is owned
  by the adapter for `provider` — this schema doesn't know what's inside it.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "integrations" do
    field :provider, :string
    field :credentials, TimingPlayTime.Encrypted.Map
    belongs_to :user, TimingPlayTime.Accounts.User, type: :binary_id

    timestamps(type: :utc_datetime)
  end

  @fields [:provider, :credentials, :user_id]

  def changeset(integration, attrs) do
    integration
    |> cast(attrs, @fields)
    |> validate_required(@fields)
    |> unique_constraint(:user_id)
  end
end
