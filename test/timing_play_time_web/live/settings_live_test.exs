defmodule TimingPlayTimeWeb.SettingsLiveTest do
  use TimingPlayTimeWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias TimingPlayTime.Accounts
  alias TimingPlayTime.Plugins.Persistence.Stub, as: PersistenceStub

  setup %{conn: conn} do
    :ok = PersistenceStub.clear_all_state()
    {:ok, user} = Accounts.create_user()
    %{conn: log_in_user(conn, user), user: user}
  end

  test "shows an empty state before a timezone or Integration are set", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/settings")

    assert html =~ "Not connected yet"
  end

  test "saving a timezone persists it", %{conn: conn, user: user} do
    {:ok, view, _html} = live(conn, ~p"/settings")

    html =
      view
      |> form("form[phx-submit=save_timezone]", %{"timezone" => "Pacific/Auckland"})
      |> render_submit()

    assert html =~ "Timezone set to Pacific/Auckland"
    assert Accounts.get_user(user.id).timezone == "Pacific/Auckland"
  end

  test "saving a Timing API key creates an Integration", %{conn: conn, user: user} do
    {:ok, view, _html} = live(conn, ~p"/settings")

    html =
      view
      |> form("form[phx-submit=save_integration_timing]", %{"api_key" => "my-secret-key"})
      |> render_submit()

    assert html =~ "Timing integration saved"

    integration = Accounts.get_integration(user)
    assert integration.provider == "timing"
    assert integration.credentials == %{"api_key" => "my-secret-key"}
  end

  test "disconnecting and reconnecting replaces the Integration, not add a second one", %{
    conn: conn,
    user: user
  } do
    {:ok, view, _html} = live(conn, ~p"/settings")

    view
    |> form("form[phx-submit=save_integration_timing]", %{"api_key" => "old-key"})
    |> render_submit()

    view |> element("button", "Disconnect") |> render_click()

    view
    |> form("form[phx-submit=save_integration_timing]", %{"api_key" => "new-key"})
    |> render_submit()

    assert Accounts.get_integration(user).credentials == %{"api_key" => "new-key"}
  end

  test "connecting RescueTime creates an Integration with provider \"rescuetime\"", %{
    conn: conn,
    user: user
  } do
    {:ok, view, _html} = live(conn, ~p"/settings")

    html =
      view
      |> form("form[phx-submit=save_integration_rescuetime]", %{"api_key" => "rt-key"})
      |> render_submit()

    assert html =~ "RescueTime integration saved"

    integration = Accounts.get_integration(user)
    assert integration.provider == "rescuetime"
    assert integration.credentials == %{"api_key" => "rt-key"}
  end

  test "connecting one provider hides the other's form", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/settings")

    html =
      view
      |> form("form[phx-submit=save_integration_timing]", %{"api_key" => "my-key"})
      |> render_submit()

    refute html =~ ~s(phx-submit="save_integration_rescuetime")
    assert html =~ "Connected to Timing"
  end

  describe "disconnecting" do
    test "with zero Activities removes the Integration immediately", %{conn: conn, user: user} do
      {:ok, _integration} =
        Accounts.upsert_integration(user, %{provider: "timing", credentials: %{"api_key" => "k"}})

      {:ok, view, _html} = live(conn, ~p"/settings")

      html = view |> element("button", "Disconnect") |> render_click()

      assert html =~ "Disconnected"
      refute html =~ "Yes, disconnect"
      assert Accounts.get_integration(user) == nil
    end

    test "with 1+ Activities shows the warning and requires a second click", %{
      conn: conn,
      user: user
    } do
      {:ok, _integration} =
        Accounts.upsert_integration(user, %{provider: "timing", credentials: %{"api_key" => "k"}})

      {:ok, _activity} =
        PersistenceStub.create_activity(user.id, %{
          name: "Coding",
          time_source_identifier: "proj-1",
          multiplier: 1.0
        })

      {:ok, view, _html} = live(conn, ~p"/settings")

      html = view |> element("button", "Disconnect") |> render_click()

      assert html =~ "Yes, disconnect"
      assert Accounts.get_integration(user) != nil

      html = view |> element("button", "Yes, disconnect") |> render_click()

      assert html =~ "Disconnected"
      assert Accounts.get_integration(user) == nil
    end

    test "canceling the warning leaves the Integration intact", %{conn: conn, user: user} do
      {:ok, _integration} =
        Accounts.upsert_integration(user, %{provider: "timing", credentials: %{"api_key" => "k"}})

      {:ok, _activity} =
        PersistenceStub.create_activity(user.id, %{
          name: "Coding",
          time_source_identifier: "proj-1",
          multiplier: 1.0
        })

      {:ok, view, _html} = live(conn, ~p"/settings")

      view |> element("button", "Disconnect") |> render_click()
      html = view |> element("button", "Cancel") |> render_click()

      refute html =~ "Yes, disconnect"
      assert Accounts.get_integration(user) != nil
    end
  end

  describe "Sign-in & devices" do
    test "anonymous User sees the unified continue affordance, no unverified state", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/settings")

      assert html =~ "Continue with email"
      assert html =~ ~s(href="/auth/continue")
      refute html =~ "unverified"
      refute html =~ "finish linking"
    end

    test "linked User sees the masked read-only line and fineprint", %{conn: conn, user: user} do
      {:ok, user} = Accounts.link_identity(user, %{sub: "email|abc", email: "maxim@example.com"})
      conn = log_in_user(conn, user)

      {:ok, _view, html} = live(conn, ~p"/settings")

      assert html =~ "m•••m@example.com"
      assert html =~ "Changing or removing this isn&#39;t available."
      assert html =~ "Sign in as someone else"
      assert html =~ ~s(href="/auth/logout")
      refute html =~ "unverified"
    end
  end
end
