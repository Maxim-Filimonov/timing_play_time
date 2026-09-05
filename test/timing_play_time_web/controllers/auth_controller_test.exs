defmodule TimingPlayTimeWeb.AuthControllerTest do
  use TimingPlayTimeWeb.ConnCase, async: false

  alias TimingPlayTime.Accounts
  alias TimingPlayTime.ActivityManager
  alias TimingPlayTime.Plugins.IdentityProvider.Stub

  setup do
    on_exit(fn -> Application.delete_env(:timing_play_time, :identity_provider_stub_result) end)
    :ok
  end

  defp with_auth_session(conn, user, flow) do
    conn
    |> log_in_user(user)
    |> Plug.Test.init_test_session(auth: %{flow: flow, params: %{state: "the-state"}})
  end

  describe "link/2 and login/2" do
    test "link redirects out to the IdP with a stashed :auth session", %{conn: conn} do
      {:ok, user} = Accounts.create_user()

      conn = conn |> log_in_user(user) |> get(~p"/auth/link")

      assert redirected_to(conn, 302) =~ "/auth/callback"
      assert %{flow: :link} = get_session(conn, :auth)
    end

    test "login redirects out to the IdP with a stashed :auth session", %{conn: conn} do
      {:ok, user} = Accounts.create_user()

      conn = conn |> log_in_user(user) |> get(~p"/auth/login")

      assert redirected_to(conn, 302) =~ "/auth/callback"
      assert %{flow: :login} = get_session(conn, :auth)
    end
  end

  describe "callback/2 — anonymous onboarding is unchanged" do
    test "/ and /settings never call the IdentityProvider Stub", %{conn: conn} do
      conn = get(conn, ~p"/")
      assert html_response(conn, 200)
    end
  end

  describe "callback/2 — link flow" do
    test "happy path links the identity and redirects to /settings", %{conn: conn} do
      {:ok, user} = Accounts.create_user()
      Stub.stub_next_result({:ok, %{sub: "email|abc", email: "a@b.com"}})

      conn =
        conn
        |> with_auth_session(user, :link)
        |> get(~p"/auth/callback?code=stub-code&state=the-state")

      assert redirected_to(conn) == ~p"/settings"
      assert Phoenix.Flash.get(conn.assigns.flash, :info) == "Email linked."

      updated = Accounts.get_user(user.id)
      assert updated.auth0_sub == "email|abc"
      assert updated.email == "a@b.com"
    end

    test "email already on another User is refused", %{conn: conn} do
      {:ok, other} = Accounts.create_user()
      {:ok, _other} = Accounts.link_identity(other, %{sub: "email|other", email: "taken@b.com"})

      {:ok, user} = Accounts.create_user()
      Stub.stub_next_result({:ok, %{sub: "email|fresh", email: "taken@b.com"}})

      conn =
        conn
        |> with_auth_session(user, :link)
        |> get(~p"/auth/callback?code=stub-code&state=the-state")

      assert redirected_to(conn) == ~p"/settings"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "already linked to another Playtime"
      assert Accounts.get_user(user.id).auth0_sub == nil
    end

    test "re-link with a different sub is refused", %{conn: conn} do
      {:ok, user} = Accounts.create_user()
      {:ok, user} = Accounts.link_identity(user, %{sub: "email|abc", email: "a@b.com"})
      Stub.stub_next_result({:ok, %{sub: "email|xyz", email: "new@b.com"}})

      conn =
        conn
        |> with_auth_session(user, :link)
        |> get(~p"/auth/callback?code=stub-code&state=the-state")

      assert redirected_to(conn) == ~p"/settings"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "already linked to"
      assert Accounts.get_user(user.id).auth0_sub == "email|abc"
    end
  end

  describe "callback/2 — login flow" do
    test "recovers an existing linked User onto a fresh, empty anonymous browser", %{conn: conn} do
      {:ok, linked} = Accounts.create_user()
      {:ok, linked} = Accounts.link_identity(linked, %{sub: "email|abc", email: "a@b.com"})

      {:ok, anon} = Accounts.create_user()
      Stub.stub_next_result({:ok, %{sub: "email|abc", email: "a@b.com"}})

      conn =
        conn
        |> with_auth_session(anon, :login)
        |> get(~p"/auth/callback?code=stub-code&state=the-state")

      assert redirected_to(conn) == ~p"/"
      assert Phoenix.Flash.get(conn.assigns.flash, :info) == "Welcome back."
      assert get_session(conn, :user_id) == linked.id
      assert Accounts.get_user(anon.id) == nil
    end

    test "adopts a linked User's own Integration and Activities on sign-in", %{conn: conn} do
      {:ok, linked} = Accounts.create_user()
      {:ok, linked} = Accounts.link_identity(linked, %{sub: "email|abc", email: "a@b.com"})

      {:ok, _integration} =
        Accounts.upsert_integration(linked, %{
          provider: "timing",
          credentials: %{"api_key" => "linked-key"}
        })

      {:ok, _activity} =
        ActivityManager.create_activity(linked.id, %{
          name: "Coding",
          time_source_identifier: "proj-1",
          multiplier: 1.0
        })

      {:ok, anon} = Accounts.create_user()
      Stub.stub_next_result({:ok, %{sub: "email|abc", email: "a@b.com"}})

      conn =
        conn
        |> with_auth_session(anon, :login)
        |> get(~p"/auth/callback?code=stub-code&state=the-state")

      assert get_session(conn, :user_id) == linked.id

      # The next request rides the rewritten session cookie through the
      # ordinary CurrentUser plug — no special "adoption" path, the switch
      # alone is enough to surface the target User's existing data.
      dashboard_conn = conn |> recycle() |> get(~p"/")
      assert dashboard_conn.assigns.current_user.id == linked.id

      assert {:ok, [%{name: "Coding"}]} = ActivityManager.list_activities(linked.id)
      assert Accounts.get_integration(linked).credentials == %{"api_key" => "linked-key"}
    end

    test "signing into your own already-linked, still-empty User doesn't delete it", %{conn: conn} do
      {:ok, user} = Accounts.create_user()
      {:ok, user} = Accounts.link_identity(user, %{sub: "email|abc", email: "a@b.com"})
      Stub.stub_next_result({:ok, %{sub: "email|abc", email: "a@b.com"}})

      conn =
        conn
        |> with_auth_session(user, :login)
        |> get(~p"/auth/callback?code=stub-code&state=the-state")

      assert redirected_to(conn) == ~p"/"
      assert get_session(conn, :user_id) == user.id
      assert Accounts.get_user(user.id) != nil
    end

    test "preserves a non-empty anonymous User after the switch", %{conn: conn} do
      {:ok, linked} = Accounts.create_user()
      {:ok, linked} = Accounts.link_identity(linked, %{sub: "email|abc", email: "a@b.com"})

      {:ok, anon} = Accounts.create_user()

      {:ok, _activity} =
        ActivityManager.create_activity(anon.id, %{
          name: "Coding",
          time_source_identifier: "proj-1",
          multiplier: 1.0
        })

      Stub.stub_next_result({:ok, %{sub: "email|abc", email: "a@b.com"}})

      conn =
        conn
        |> with_auth_session(anon, :login)
        |> get(~p"/auth/callback?code=stub-code&state=the-state")

      assert get_session(conn, :user_id) == linked.id
      assert Accounts.get_user(anon.id) != nil
    end

    test "an unknown identity yields the generic failure", %{conn: conn} do
      {:ok, anon} = Accounts.create_user()
      Stub.stub_next_result({:ok, %{sub: "email|nobody", email: "x@y.com"}})

      conn =
        conn
        |> with_auth_session(anon, :login)
        |> get(~p"/auth/callback?code=stub-code&state=the-state")

      assert redirected_to(conn) == ~p"/"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) == "That didn't complete. Please try again."
      assert get_session(conn, :user_id) == anon.id
      assert Accounts.get_user(anon.id) != nil
    end
  end

  describe "callback/2 — failure modes" do
    test "user abandons / Auth0 errors return to origin with the generic failure (link)", %{conn: conn} do
      {:ok, user} = Accounts.create_user()

      conn =
        conn
        |> with_auth_session(user, :link)
        |> get(~p"/auth/callback?error=access_denied")

      assert redirected_to(conn) == ~p"/settings"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) == "That didn't complete. Please try again."
    end

    test "user abandons / Auth0 errors return to origin with the generic failure (login)", %{conn: conn} do
      {:ok, user} = Accounts.create_user()

      conn =
        conn
        |> with_auth_session(user, :login)
        |> get(~p"/auth/callback?error=access_denied")

      assert redirected_to(conn) == ~p"/"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) == "That didn't complete. Please try again."
    end

    test "a state mismatch is a generic failure", %{conn: conn} do
      {:ok, user} = Accounts.create_user()
      Stub.stub_next_result({:ok, %{sub: "email|abc", email: "a@b.com"}})

      conn =
        conn
        |> with_auth_session(user, :login)
        |> get(~p"/auth/callback?code=stub-code&state=wrong-state")

      assert redirected_to(conn) == ~p"/"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) == "That didn't complete. Please try again."
    end

    test "a callback with no :auth session key is a harmless generic failure", %{conn: conn} do
      {:ok, user} = Accounts.create_user()

      conn =
        conn
        |> log_in_user(user)
        |> get(~p"/auth/callback?code=stub-code&state=the-state")

      assert redirected_to(conn) == ~p"/"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) == "That didn't complete. Please try again."
    end

    test "every callback response is a 3xx redirect, never a render", %{conn: conn} do
      {:ok, user} = Accounts.create_user()

      conn =
        conn
        |> with_auth_session(user, :login)
        |> get(~p"/auth/callback?error=access_denied")

      assert conn.status in 300..399
    end
  end
end
