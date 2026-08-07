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

  test "renders with zero Today figures, rather than crashing, for a User with no timezone configured yet" do
    {:ok, user} = Accounts.create_user()
    conn = Phoenix.ConnTest.build_conn() |> log_in_user(user)

    {:ok, _activity} =
      PersistenceStub.create_activity(user.id, %{
        name: "Coding",
        time_source_identifier: "coding-proj-1",
        multiplier: 2.0,
        activated_at: DateTime.add(DateTime.utc_now(), -3, :day)
      })

    {:ok, _view, html} = live(conn, ~p"/")

    assert html =~ "Coding"
  end

  test "shows today's minutes and Play Minutes per Activity, and labels Manual Sync as Pushscroll Balance",
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
    # Play Minutes is abbreviated as "min" under an hour, "hr" at/over an
    # hour (see TimingPlayTimeWeb.Components.TimeDisplay) — either is valid
    # here since the stub time source's output varies with time of day.
    assert html =~ ~r/play\s*<span/
    assert html =~ "Pushscroll Balance"
    refute html =~ "Manual Sync"
  end

  test "shows a This Week figure per Activity, alongside Today (ADR-0010's Entry Expiry Window)",
       %{conn: conn, user: user} do
    {:ok, _activity} =
      PersistenceStub.create_activity(user.id, %{
        name: "Coding",
        time_source_identifier: "coding-proj-1",
        multiplier: 2.0,
        activated_at: DateTime.add(DateTime.utc_now(), -3, :day)
      })

    {:ok, _view, html} = live(conn, ~p"/")

    assert html =~ "This week:"
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

  test "logging Playtime Used flashes a Spend Receipt naming which Activity funded it (ADR-0010)",
       %{conn: conn, user: user} do
    {:ok, _activity} =
      PersistenceStub.create_activity(user.id, %{
        name: "Coding",
        time_source_identifier: "coding-proj-1",
        multiplier: 1.0,
        activated_at: DateTime.add(DateTime.utc_now(), -3, :day)
      })

    {:ok, view, _html} = live(conn, ~p"/")

    html =
      view
      |> form("form[phx-submit=log_playtime]", %{"minutes" => "5.0"})
      |> render_submit()

    assert html =~ "Logged 5.0 play minutes!"
    assert html =~ "Funded by Coding: 5.0."
  end

  test "logging Playtime Used with no Activities still flashes, with no Spend Receipt clause",
       %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    html =
      view
      |> form("form[phx-submit=log_playtime]", %{"minutes" => "5.0"})
      |> render_submit()

    assert html =~ "Logged 5.0 play minutes!"
    refute html =~ "Funded by"
  end

  test "setting the Pushscroll Balance flashes the new copy", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    html =
      view
      |> form("form[phx-submit=set_manual_sync]", %{"minutes" => "42"})
      |> render_submit()

    assert html =~ "Pushscroll Balance set to 42.0 minutes!"
  end

  test "links to the settings page", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/")

    assert html =~ ~s(href="/settings")
  end

  test "shows the day-scoped Playtime hero, with the cumulative Play Balance hidden by default", %{
    conn: conn,
    user: user
  } do
    {:ok, _activity} =
      PersistenceStub.create_activity(user.id, %{
        name: "Coding",
        time_source_identifier: "coding-proj-1",
        multiplier: 1.0,
        activated_at: DateTime.add(DateTime.utc_now(), -3, :day)
      })

    {:ok, _view, html} = live(conn, ~p"/")

    assert html =~ "Playtime"
    assert html =~ "Earned Today"
    assert html =~ "Used Today"
    assert html =~ "Pushscroll Balance"
    assert html =~ "Reserve"
    refute html =~ "Your Play Balance"
  end

  test "shows the week_earned/week_used reconciliation under the Playtime hero (ADR-0010)", %{
    conn: conn,
    user: user
  } do
    {:ok, _activity} =
      PersistenceStub.create_activity(user.id, %{
        name: "Coding",
        time_source_identifier: "coding-proj-1",
        multiplier: 1.0,
        activated_at: DateTime.add(DateTime.utc_now(), -3, :day)
      })

    {:ok, _view, html} = live(conn, ~p"/")

    assert html =~ "earned this week"
    assert html =~ "used this week"
    assert html =~ "This Week"
  end

  test "clicking Edit on an Activity shows an inline form pre-filled with its current values", %{
    conn: conn,
    user: user
  } do
    {:ok, activity} =
      PersistenceStub.create_activity(user.id, %{
        name: "Coding",
        time_source_identifier: "coding-proj-1",
        multiplier: 1.5,
        activated_at: DateTime.utc_now()
      })

    {:ok, view, _html} = live(conn, ~p"/")

    html = render_click(view, "edit_activity", %{"id" => activity.id})

    assert html =~ ~s(value="Coding")
    assert html =~ ~s(value="coding-proj-1")
    assert html =~ ~s(value="1.5")
  end

  test "clicking Cancel while editing an Activity returns to the display view", %{
    conn: conn,
    user: user
  } do
    {:ok, activity} =
      PersistenceStub.create_activity(user.id, %{
        name: "Coding",
        time_source_identifier: "coding-proj-1",
        multiplier: 1.5,
        activated_at: DateTime.utc_now()
      })

    {:ok, view, _html} = live(conn, ~p"/")

    render_click(view, "edit_activity", %{"id" => activity.id})
    html = render_click(view, "cancel_edit_activity", %{"id" => activity.id})

    refute html =~ ~s(value="coding-proj-1")
  end

  test "clicking + on the multiplier stepper while editing bumps the displayed value by 0.1", %{
    conn: conn,
    user: user
  } do
    {:ok, activity} =
      PersistenceStub.create_activity(user.id, %{
        name: "Coding",
        time_source_identifier: "coding-proj-1",
        multiplier: 1.5,
        activated_at: DateTime.utc_now()
      })

    {:ok, view, _html} = live(conn, ~p"/")

    render_click(view, "edit_activity", %{"id" => activity.id})
    html = render_click(view, "increment_multiplier", %{})

    assert html =~ ~s(value="1.6")
    refute html =~ ~s(value="1.5")
  end

  test "clicking - on the multiplier stepper while editing decrements the displayed value by 0.1, clamped at 0.0",
       %{conn: conn, user: user} do
    {:ok, activity} =
      PersistenceStub.create_activity(user.id, %{
        name: "Coding",
        time_source_identifier: "coding-proj-1",
        multiplier: 0.05,
        activated_at: DateTime.utc_now()
      })

    {:ok, view, _html} = live(conn, ~p"/")

    render_click(view, "edit_activity", %{"id" => activity.id})
    html = render_click(view, "decrement_multiplier", %{})

    assert html =~ ~s(value="0.0")
  end

  test "submitting the edit form saves the new name, source id, and stepped multiplier", %{
    conn: conn,
    user: user
  } do
    {:ok, activity} =
      PersistenceStub.create_activity(user.id, %{
        name: "Coding",
        time_source_identifier: "coding-proj-1",
        multiplier: 1.5,
        activated_at: DateTime.utc_now()
      })

    {:ok, view, _html} = live(conn, ~p"/")

    render_click(view, "edit_activity", %{"id" => activity.id})
    render_click(view, "increment_multiplier", %{})

    html =
      view
      |> form("form[phx-submit=save_activity]", %{
        "name" => "Deep Work",
        "time_source_identifier" => "deep-work-proj"
      })
      |> render_submit()

    assert html =~ "Deep Work"
    assert html =~ "deep-work-proj"
    assert html =~ "1.6"
    refute html =~ ~s(value="Deep Work")

    assert {:ok, saved} = PersistenceStub.get_activity(user.id, activity.id)
    assert saved.name == "Deep Work"
    assert saved.time_source_identifier == "deep-work-proj"
    assert saved.multiplier == 1.6
  end

  test "reveals the cumulative Play Balance debug overlay on reveal_debug, and hides it again on hide_debug",
       %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/")
    refute html =~ "Your Play Balance"

    html = render_hook(view, "reveal_debug", %{})
    assert html =~ "Your Play Balance"

    html = render_click(view, "hide_debug")
    refute html =~ "Your Play Balance"
  end
end
