defmodule TimingPlayTime.Accounts do
  @moduledoc """
  Context for Users and Integrations (ADR-0006, ADR-0007), and for optional
  Auth0-linked identities (ADR-0015).
  """

  alias TimingPlayTime.Repo
  alias TimingPlayTime.Accounts.User
  alias TimingPlayTime.Accounts.Integration
  alias TimingPlayTime.ActivityManager
  alias TimingPlayTime.ManualSync
  alias TimingPlayTime.PlaytimeUsed

  @type identity :: %{sub: String.t(), email: String.t()}

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

  @doc """
  Removes a User's Integration (ADR-0016's Settings disconnect flow). A
  no-op returning `{:ok, nil}` when there is none — disconnecting twice, or
  disconnecting a User who never connected, isn't an error.
  """
  @spec delete_integration(User.t()) :: {:ok, Integration.t() | nil} | {:error, term()}
  def delete_integration(%User{} = user) do
    case get_integration(user) do
      nil -> {:ok, nil}
      integration -> Repo.delete(integration)
    end
  end

  @doc """
  Links a verified Auth0 identity to `user` (an existing, typically anonymous
  User). Idempotent: relinking `user` with its own current sub re-syncs
  `email`, returns `{:ok, user}`.
  """
  @spec link_identity(User.t(), identity()) ::
          {:ok, User.t()}
          | {:error, :already_linked}
          | {:error, :identity_taken}
  def link_identity(%User{auth0_sub: sub} = user, %{sub: sub} = identity) when not is_nil(sub) do
    write_identity(user, identity)
  end

  def link_identity(%User{auth0_sub: existing}, _identity) when not is_nil(existing) do
    {:error, :already_linked}
  end

  def link_identity(%User{} = user, %{sub: sub, email: email} = identity) do
    if Repo.get_by(User, auth0_sub: sub) || Repo.get_by(User, email: email) do
      {:error, :identity_taken}
    else
      write_identity(user, identity)
    end
  end

  defp write_identity(user, %{sub: sub, email: email}) do
    user
    |> User.identity_changeset(%{auth0_sub: sub, email: email})
    |> Repo.update()
    |> case do
      {:ok, user} -> {:ok, user}
      {:error, _changeset} -> {:error, :identity_taken}
    end
  end

  @doc """
  Resolves a verified Auth0 identity to the User that owns it, for the
  sign-in flow. Lookup by `auth0_sub` ONLY. On a hit, re-syncs the email
  display copy (same-sub upsert).
  """
  @spec authenticate_identity(identity()) :: {:ok, User.t()} | {:error, :no_user}
  def authenticate_identity(%{sub: sub} = identity) do
    case Repo.get_by(User, auth0_sub: sub) do
      nil -> {:error, :no_user}
      user -> write_identity(user, identity)
    end
  end

  @doc """
  Hard-deletes `user` iff provably empty: no Activities, no Integration, no
  Playtime Used, no Manual Sync. Non-empty is left untouched either way.
  """
  @spec discard_if_empty(User.t()) :: :ok
  def discard_if_empty(%User{} = user) do
    if empty?(user) do
      Repo.delete(user)
    end

    :ok
  end

  defp empty?(user) do
    no_activities?(user) and no_integration?(user) and no_playtime_used?(user) and
      no_manual_sync?(user)
  end

  defp no_activities?(user) do
    case ActivityManager.list_activities(user.id) do
      {:ok, activities} -> activities == []
      {:error, _reason} -> false
    end
  end

  defp no_integration?(user), do: get_integration(user) == nil

  defp no_playtime_used?(user) do
    case PlaytimeUsed.list_all(user.id) do
      {:ok, usages} -> usages == []
      {:error, _reason} -> false
    end
  end

  defp no_manual_sync?(user) do
    case ManualSync.get_total(user.id) do
      {:ok, total} -> total in [0.0, nil]
      {:error, _reason} -> false
    end
  end

  @doc "True when `user` has 0 Activities AND no Integration — the cookie-less-arrival signature."
  @spec arrival_user?(User.t()) :: boolean()
  def arrival_user?(%User{} = user), do: no_activities?(user) and no_integration?(user)

  @doc "Sets arrival_banner_dismissed (the dashboard banner's 'I'm new — hide this')."
  @spec dismiss_arrival_banner(User.t()) :: {:ok, User.t()}
  def dismiss_arrival_banner(%User{} = user) do
    user
    |> User.arrival_banner_changeset(%{arrival_banner_dismissed: true})
    |> Repo.update()
  end
end
