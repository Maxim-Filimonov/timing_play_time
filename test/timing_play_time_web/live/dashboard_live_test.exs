defmodule TimingPlayTimeWeb.DashboardLiveTest do
  use TimingPlayTimeWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias TimingPlayTime.Plugins.Persistence.Stub, as: PersistenceStub

  setup do
    :ok = PersistenceStub.clear_all_state()
    %{}
  end

  test "shows today's minutes and Play Minutes per Activity, and labels Manual Sync as Exercise Minutes",
       %{conn: conn} do
    {:ok, _activity} =
      PersistenceStub.create_activity(%{
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

  test "setting exercise minutes flashes the new copy", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    html =
      view
      |> form("form[phx-submit=set_manual_sync]", %{"minutes" => "42"})
      |> render_submit()

    assert html =~ "Exercise minutes set to 42.0 minutes!"
  end
end
