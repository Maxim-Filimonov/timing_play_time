defmodule TimingPlayTime.AccountsTest do
  use TimingPlayTime.DataCase, async: true

  alias TimingPlayTime.Accounts
  alias TimingPlayTime.ActivityManager
  alias TimingPlayTime.ManualSync
  alias TimingPlayTime.PlaytimeUsed

  describe "create_user/0" do
    test "creates a User with no timezone or Integration yet" do
      assert {:ok, user} = Accounts.create_user()
      assert user.id
      assert user.timezone == nil
    end
  end

  describe "get_user/1" do
    test "returns the User for a valid id" do
      {:ok, user} = Accounts.create_user()
      assert %{id: id} = Accounts.get_user(user.id)
      assert id == user.id
    end

    test "returns nil for a missing id" do
      assert Accounts.get_user(Ecto.UUID.generate()) == nil
    end

    test "returns nil for a malformed id (stale/tampered cookie), rather than raising" do
      assert Accounts.get_user("not-a-uuid") == nil
    end
  end

  describe "update_timezone/2" do
    test "sets the timezone" do
      {:ok, user} = Accounts.create_user()
      assert {:ok, updated} = Accounts.update_timezone(user, "Pacific/Auckland")
      assert updated.timezone == "Pacific/Auckland"
    end
  end

  describe "get_integration/1 and upsert_integration/2" do
    test "returns nil when the user has no Integration yet" do
      {:ok, user} = Accounts.create_user()
      assert Accounts.get_integration(user) == nil
    end

    test "creates an Integration and round-trips credentials through encryption" do
      {:ok, user} = Accounts.create_user()

      assert {:ok, integration} =
               Accounts.upsert_integration(user, %{
                 provider: "timing",
                 credentials: %{"api_key" => "secret-123"}
               })

      assert integration.provider == "timing"
      assert integration.credentials == %{"api_key" => "secret-123"}

      fetched = Accounts.get_integration(user)
      assert fetched.credentials == %{"api_key" => "secret-123"}
    end

    test "replaces (not duplicates) the existing Integration for the same user" do
      {:ok, user} = Accounts.create_user()

      {:ok, _first} =
        Accounts.upsert_integration(user, %{
          provider: "timing",
          credentials: %{"api_key" => "old-key"}
        })

      assert {:ok, second} =
               Accounts.upsert_integration(user, %{
                 provider: "timing",
                 credentials: %{"api_key" => "new-key"}
               })

      assert second.credentials == %{"api_key" => "new-key"}
      assert Accounts.get_integration(user).credentials == %{"api_key" => "new-key"}
      assert Repo.aggregate(TimingPlayTime.Accounts.Integration, :count) == 1
    end

    test "one user's Integration is isolated from another's" do
      {:ok, user_a} = Accounts.create_user()
      {:ok, user_b} = Accounts.create_user()

      {:ok, _} =
        Accounts.upsert_integration(user_a, %{
          provider: "timing",
          credentials: %{"api_key" => "a-key"}
        })

      assert Accounts.get_integration(user_b) == nil
    end

    test "creates a RescueTime Integration" do
      {:ok, user} = Accounts.create_user()

      assert {:ok, integration} =
               Accounts.upsert_integration(user, %{
                 provider: "rescuetime",
                 credentials: %{"api_key" => "rt-secret"}
               })

      assert integration.provider == "rescuetime"
    end

    test "rejects an unknown provider" do
      {:ok, user} = Accounts.create_user()

      assert {:error, changeset} =
               Accounts.upsert_integration(user, %{
                 provider: "some-other-app",
                 credentials: %{"api_key" => "x"}
               })

      assert "is invalid" in errors_on(changeset).provider
    end
  end

  describe "delete_integration/1" do
    test "removes an existing Integration" do
      {:ok, user} = Accounts.create_user()

      {:ok, _} =
        Accounts.upsert_integration(user, %{
          provider: "timing",
          credentials: %{"api_key" => "key"}
        })

      assert {:ok, _integration} = Accounts.delete_integration(user)
      assert Accounts.get_integration(user) == nil
    end

    test "is a no-op returning {:ok, nil} when there is none" do
      {:ok, user} = Accounts.create_user()

      assert {:ok, nil} = Accounts.delete_integration(user)
    end
  end

  describe "link_identity/2" do
    test "links a verified identity to an unlinked User" do
      {:ok, user} = Accounts.create_user()

      assert {:ok, linked} =
               Accounts.link_identity(user, %{sub: "email|abc", email: "a@b.com"})

      assert linked.auth0_sub == "email|abc"
      assert linked.email == "a@b.com"
    end

    test "re-linking with the same sub is idempotent and re-syncs email" do
      {:ok, user} = Accounts.create_user()
      {:ok, user} = Accounts.link_identity(user, %{sub: "email|abc", email: "old@b.com"})

      assert {:ok, relinked} =
               Accounts.link_identity(user, %{sub: "email|abc", email: "new@b.com"})

      assert relinked.auth0_sub == "email|abc"
      assert relinked.email == "new@b.com"
    end

    test "refuses to re-link with a different sub" do
      {:ok, user} = Accounts.create_user()
      {:ok, user} = Accounts.link_identity(user, %{sub: "email|abc", email: "a@b.com"})

      assert Accounts.link_identity(user, %{sub: "email|xyz", email: "a@b.com"}) ==
               {:error, :already_linked}

      assert Accounts.get_user(user.id).auth0_sub == "email|abc"
    end

    test "refuses a sub already claimed by another User" do
      {:ok, other} = Accounts.create_user()
      {:ok, _other} = Accounts.link_identity(other, %{sub: "email|taken", email: "taken@b.com"})

      {:ok, user} = Accounts.create_user()

      assert Accounts.link_identity(user, %{sub: "email|taken", email: "fresh@b.com"}) ==
               {:error, :identity_taken}

      assert Accounts.get_user(user.id).auth0_sub == nil
    end

    test "refuses an email already claimed by another User" do
      {:ok, other} = Accounts.create_user()
      {:ok, _other} = Accounts.link_identity(other, %{sub: "email|other", email: "taken@b.com"})

      {:ok, user} = Accounts.create_user()

      assert Accounts.link_identity(user, %{sub: "email|fresh", email: "taken@b.com"}) ==
               {:error, :identity_taken}
    end

    test "a unique_constraint race is mapped to :identity_taken" do
      {:ok, other} = Accounts.create_user()
      {:ok, _other} = Accounts.link_identity(other, %{sub: "email|race", email: "race@b.com"})

      {:ok, user} = Accounts.create_user()

      # Simulate the race backstop directly against the changeset/Repo path,
      # bypassing the app-level pre-check that would otherwise catch this.
      changeset =
        TimingPlayTime.Accounts.User.identity_changeset(user, %{
          auth0_sub: "email|race",
          email: "someone-else@b.com"
        })

      assert {:error, changeset} = Repo.update(changeset)
      assert "has already been taken" in errors_on(changeset).auth0_sub
    end
  end

  describe "authenticate_identity/1" do
    test "resolves a known sub and re-syncs the email" do
      {:ok, user} = Accounts.create_user()
      {:ok, user} = Accounts.link_identity(user, %{sub: "email|abc", email: "old@b.com"})

      assert {:ok, authed} = Accounts.authenticate_identity(%{sub: "email|abc", email: "new@b.com"})
      assert authed.id == user.id
      assert authed.email == "new@b.com"
    end

    test "returns :no_user for an unknown sub" do
      assert Accounts.authenticate_identity(%{sub: "email|missing", email: "x@y.com"}) ==
               {:error, :no_user}
    end
  end

  describe "discard_if_empty/1" do
    test "deletes a fully-empty User" do
      {:ok, user} = Accounts.create_user()

      assert Accounts.discard_if_empty(user) == :ok
      assert Accounts.get_user(user.id) == nil
    end

    test "keeps a User with an Activity" do
      {:ok, user} = Accounts.create_user()

      {:ok, _activity} =
        ActivityManager.create_activity(user.id, %{
          name: "Coding",
          time_source_identifier: "proj-1",
          multiplier: 1.0
        })

      assert Accounts.discard_if_empty(user) == :ok
      assert Accounts.get_user(user.id) != nil
    end

    test "keeps a User with an Integration" do
      {:ok, user} = Accounts.create_user()

      {:ok, _integration} =
        Accounts.upsert_integration(user, %{
          provider: "timing",
          credentials: %{"api_key" => "key"}
        })

      assert Accounts.discard_if_empty(user) == :ok
      assert Accounts.get_user(user.id) != nil
    end

    test "keeps a User with Playtime Used" do
      {:ok, user} = Accounts.create_user()
      {:ok, _usage} = PlaytimeUsed.log_usage(user.id, 30.0)

      assert Accounts.discard_if_empty(user) == :ok
      assert Accounts.get_user(user.id) != nil
    end

    test "keeps a User with a non-zero Manual Sync total" do
      {:ok, user} = Accounts.create_user()
      {:ok, _total} = ManualSync.set_total(user.id, 15.0)

      assert Accounts.discard_if_empty(user) == :ok
      assert Accounts.get_user(user.id) != nil
    end
  end

  describe "arrival_user?/1" do
    test "true for a User with 0 Activities and no Integration" do
      {:ok, user} = Accounts.create_user()
      assert Accounts.arrival_user?(user) == true
    end

    test "false once the User has an Activity" do
      {:ok, user} = Accounts.create_user()

      {:ok, _activity} =
        ActivityManager.create_activity(user.id, %{
          name: "Coding",
          time_source_identifier: "proj-1",
          multiplier: 1.0
        })

      assert Accounts.arrival_user?(user) == false
    end

    test "false once the User has an Integration" do
      {:ok, user} = Accounts.create_user()

      {:ok, _integration} =
        Accounts.upsert_integration(user, %{
          provider: "timing",
          credentials: %{"api_key" => "key"}
        })

      assert Accounts.arrival_user?(user) == false
    end
  end

  describe "dismiss_arrival_banner/1" do
    test "sets arrival_banner_dismissed" do
      {:ok, user} = Accounts.create_user()
      assert user.arrival_banner_dismissed == false

      assert {:ok, updated} = Accounts.dismiss_arrival_banner(user)
      assert updated.arrival_banner_dismissed == true
    end
  end
end
