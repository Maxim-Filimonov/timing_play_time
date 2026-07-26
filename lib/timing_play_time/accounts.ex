defmodule TimingPlayTime.Accounts do
  @moduledoc """
  Context for Users and Integrations (ADR-0006, ADR-0007).
  """

  alias TimingPlayTime.Repo
  alias TimingPlayTime.Accounts.User
  alias TimingPlayTime.Accounts.Integration

  @doc "Creates a new User with no timezone/Integration set yet."
  def create_user do
    Repo.insert(%User{})
  end

  @doc """
  Fetches a User by id. Returns `nil` for a missing or malformed id (e.g. a
  stale/tampered session cookie) rather than raising, since callers treat a
  missing User the same as "no session yet."
  """
  def get_user(id) when is_binary(id) do
    Repo.get(User, id)
  rescue
    Ecto.Query.CastError -> nil
  end

  def get_user(_id), do: nil

  @doc "Sets a User's timezone (browser Intl auto-detect on first visit, or Settings)."
  def update_timezone(%User{} = user, timezone) do
    user
    |> User.timezone_changeset(%{timezone: timezone})
    |> Repo.update()
  end

  @doc "Gets a User's Integration, if they've configured one."
  def get_integration(%User{} = user) do
    Repo.get_by(Integration, user_id: user.id)
  end

  @doc """
  Creates or replaces a User's Integration (there is at most one at a time,
  per ADR-0007 — this always overwrites, it doesn't add a second row).
  """
  def upsert_integration(%User{} = user, attrs) do
    integration = get_integration(user) || %Integration{user_id: user.id}

    integration
    |> Integration.changeset(Map.put(attrs, :user_id, user.id))
    |> Repo.insert_or_update()
  end
end
