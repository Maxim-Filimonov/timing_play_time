defmodule TimingPlayTime.AccountsTest do
  use TimingPlayTime.DataCase, async: true

  alias TimingPlayTime.Accounts

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
  end
end
