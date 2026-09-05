defmodule TimingPlayTime.Accounts.User do
  @moduledoc """
  The tenant boundary (ADR-0006). Identity is an anonymous session cookie by
  default; a User may optionally link a verified email via Auth0 passwordless
  login (ADR-0015) to sign in on another device or after cookie loss.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "users" do
    field :timezone, :string
    field :auth0_sub, :string
    field :email, :string
    field :arrival_banner_dismissed, :boolean, default: false

    timestamps(type: :utc_datetime)
  end

  def timezone_changeset(user, attrs) do
    user
    |> cast(attrs, [:timezone])
    |> validate_required([:timezone])
  end

  @doc """
  Writes a verified Auth0 identity. Used only by `Accounts.link_identity/2`
  and the same-sub re-sync in `Accounts.authenticate_identity/1`.
  """
  def identity_changeset(user, attrs) do
    user
    |> cast(attrs, [:auth0_sub, :email])
    |> validate_required([:auth0_sub, :email])
    |> unique_constraint(:auth0_sub)
    |> unique_constraint(:email)
  end

  def arrival_banner_changeset(user, attrs) do
    cast(user, attrs, [:arrival_banner_dismissed])
  end
end
