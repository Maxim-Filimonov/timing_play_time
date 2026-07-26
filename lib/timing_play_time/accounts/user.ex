defmodule TimingPlayTime.Accounts.User do
  @moduledoc """
  The tenant boundary (ADR-0006). Identity is an anonymous session cookie,
  not a login — there is no password/email field.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "users" do
    field :timezone, :string

    timestamps(type: :utc_datetime)
  end

  def timezone_changeset(user, attrs) do
    user
    |> cast(attrs, [:timezone])
    |> validate_required([:timezone])
  end
end
