defmodule TimingPlayTimeWeb.DashboardLiveTest do
  # async: false — this suite exercises TimingPlayTime.Plugins.Persistence.Stub,
  # a single globally-named GenServer shared by every test in the process;
  # clear_all_state/0 racing against other async Stub-backed test modules
  # causes intermittent cross-test data wipes.
  use TimingPlayTimeWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias TimingPlayTime.Accounts
  alias TimingPlayTime.Plugins.Persistence.Stub, as: PersistenceStub

  setup %{conn: conn} do
    :ok = PersistenceStub.clear_all_state()
    {:ok, user} = Accounts.create_user()
    {:ok, user} = Accounts.update_timezone(user, "Pacific/Auckland")

    %{conn: log_in_user(conn, user), user: user}
  end

  test "auto-provisions an anonymous User on first visit (no session cookie yet)" do
    conn = Phoenix.ConnTest.build_conn() |> get(~p"/")
    user_id = Plug.Conn.get_session(conn, :user_id)

    assert user_id
    assert Accounts.get_user(user_id)
  end

  test "shows today's minutes and Play Minutes per Activity, and labels Manual Sync as Exercise Minutes",
       %{conn: conn, user: user} do
    {:ok, _activity} =
      PersistenceStub.create_activity(user.id, %{
        name: "Coding",
        time_source_identifier: "coding-proj-1",
        multiplier: 2.0,
        activated_at: DateTime.add(DateTime.utc_now(), -3, :day)
      })

    {:ok, _view, html} = live(conn, ~p"/")

    assert html =~ "Coding"
    assert html =~ "Today:"
    assert html =~ "play min"
    assert html =~ "Exercise Minutes"
    refute html =~ "Manual Sync"
  end

  test "does not show another user's Activities", %{conn: conn, user: user} do
    {:ok, other_user} = Accounts.create_user()

    {:ok, _mine} =
      PersistenceStub.create_activity(user.id, %{
        name: "Mine",
        time_source_identifier: "mine-proj",
        multiplier: 1.0,
        activated_at: DateTime.utc_now()
      })

    {:ok, _theirs} =
      PersistenceStub.create_activity(other_user.id, %{
        name: "TheirActivity",
        time_source_identifier: "their-proj",
        multiplier: 1.0,
        activated_at: DateTime.utc_now()
      })

    {:ok, _view, html} = live(conn, ~p"/")

    assert html =~ "Mine"
    refute html =~ "TheirActivity"
  end

  test "setting exercise minutes flashes the new copy", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    html =
      view
      |> form("form[phx-submit=set_manual_sync]", %{"minutes" => "42"})
      |> render_submit()

    assert html =~ "Exercise minutes set to 42.0 minutes!"
  end

  test "links to the settings page", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/")

    assert html =~ ~s(href="/settings")
  end
end
