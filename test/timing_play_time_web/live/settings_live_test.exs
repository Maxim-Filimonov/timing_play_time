defmodule TimingPlayTimeWeb.SettingsLiveTest do
  use TimingPlayTimeWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias TimingPlayTime.Accounts

  setup %{conn: conn} do
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
      |> form("form[phx-submit=save_integration]", %{"api_key" => "my-secret-key"})
      |> render_submit()

    assert html =~ "Timing integration saved"

    integration = Accounts.get_integration(user)
    assert integration.provider == "timing"
    assert integration.credentials == %{"api_key" => "my-secret-key"}
  end

  test "saving a second API key replaces the first, not add a second Integration", %{
    conn: conn,
    user: user
  } do
    {:ok, view, _html} = live(conn, ~p"/settings")

    view |> form("form[phx-submit=save_integration]", %{"api_key" => "old-key"}) |> render_submit()
    view |> form("form[phx-submit=save_integration]", %{"api_key" => "new-key"}) |> render_submit()

    assert Accounts.get_integration(user).credentials == %{"api_key" => "new-key"}
  end
end
