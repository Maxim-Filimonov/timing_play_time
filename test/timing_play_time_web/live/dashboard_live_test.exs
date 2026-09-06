defmodule TimingPlayTimeWeb.DashboardLiveTest do
  # async: false — this suite exercises TimingPlayTime.Plugins.Persistence.Stub,
  # a single globally-named GenServer shared by every test in the process;
  # clear_all_state/0 racing against other async Stub-backed test modules
  # causes intermittent cross-test data wipes.
  use TimingPlayTimeWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias TimingPlayTime.Accounts
  alias TimingPlayTime.Plugins.Persistence.Stub, as: PersistenceStub
  alias TimingPlayTime.Plugins.TimeSource.Stub, as: TimeSourceStub

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

  test "refuses to log playtime while the time source is unreachable, rather than recording a permanent deficit",
       %{conn: conn, user: user} do
    {:ok, _activity} =
      PersistenceStub.create_activity(user.id, %{
        name: "Coding",
        time_source_identifier: "coding-proj-1",
        multiplier: 1.0,
        activated_at: DateTime.add(DateTime.utc_now(), -3, :day)
      })

    {:ok, view, _html} = live(conn, ~p"/")

    TimeSourceStub.fail_list_entries({:error, :timing_unavailable})
    on_exit(fn -> TimeSourceStub.fail_list_entries(nil) end)

    html =
      view
      |> form("form[phx-submit=log_playtime]", %{"minutes" => "5.0"})
      |> render_submit()

    assert html =~ "Couldn&#39;t log playtime"
    assert {:ok, []} = PersistenceStub.list_playtime_used(user.id)
    assert {:ok, []} = PersistenceStub.list_entry_consumption(user.id)
  end

  test "disables the Log Playtime button while the spend is in flight, so a double-submit can't draw the same entries twice",
       %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/")

    assert html =~ ~s(phx-disable-with="Logging...")
  end

  test "points a User with no timezone at Settings instead of crashing when they log playtime" do
    {:ok, user} = Accounts.create_user()
    conn = Phoenix.ConnTest.build_conn() |> log_in_user(user)

    {:ok, view, _html} = live(conn, ~p"/")

    html =
      view
      |> form("form[phx-submit=log_playtime]", %{"minutes" => "5.0"})
      |> render_submit()

    assert html =~ "Set your timezone in Settings to log playtime"
    assert {:ok, []} = PersistenceStub.list_playtime_used(user.id)
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

  describe "Activity card Effect treatment (#16)" do
    test "an earner card shows a teal left rail and a +N× teal chip, band-indexed", %{
      conn: conn,
      user: user
    } do
      {:ok, _activity} =
        PersistenceStub.create_activity(user.id, %{
          name: "Coding",
          time_source_identifier: "coding-proj-1",
          multiplier: 1.0,
          effect: :positive,
          activated_at: DateTime.add(DateTime.utc_now(), -3, :day)
        })

      {:ok, _view, html} = live(conn, ~p"/")

      # multiplier 1.0 -> band 1 -> teal-500
      assert html =~ "border-l-teal-500"
      assert html =~ "bg-teal-500"
      assert html =~ "+1.0×"
      refute html =~ "Multiplier:"
    end

    test "a drain card shows a red left rail, a −N× red chip, and a negative red weekly figure", %{
      conn: conn,
      user: user
    } do
      {:ok, _activity} =
        PersistenceStub.create_activity(user.id, %{
          name: "YouTube",
          time_source_identifier: "youtube-proj-1",
          multiplier: 2.0,
          effect: :negative,
          activated_at: DateTime.add(DateTime.utc_now(), -3, :day)
        })

      {:ok, _view, html} = live(conn, ~p"/")

      # multiplier 2.0 -> band 2 -> red-500
      assert html =~ "border-l-red-500"
      assert html =~ "bg-red-500"
      assert html =~ "−2.0×"
      # a drain's weekly/today play figures render negative and red
      assert html =~ ~r/−<span class="font-semibold text-red-700"/
    end
  end

  describe "weekly distribution chart (#16)" do
    test "a User with tracked time but no drain Activity sees a plain upward column chart", %{
      conn: conn,
      user: user
    } do
      {:ok, _activity} =
        PersistenceStub.create_activity(user.id, %{
          name: "Coding",
          time_source_identifier: "coding-proj-1",
          multiplier: 1.0,
          effect: :positive,
          activated_at: DateTime.add(DateTime.utc_now(), -10, :day)
        })

      {:ok, _view, html} = live(conn, ~p"/")

      assert html =~ "This week by day"
      assert html =~ ~s(data-chart="upward")
      refute html =~ ~s(data-chart="diverging")
    end

    test "a User with a drain Activity configured sees the diverging form", %{
      conn: conn,
      user: user
    } do
      {:ok, _earner} =
        PersistenceStub.create_activity(user.id, %{
          name: "Coding",
          time_source_identifier: "coding-proj-1",
          multiplier: 1.0,
          effect: :positive,
          activated_at: DateTime.add(DateTime.utc_now(), -10, :day)
        })

      {:ok, _drain} =
        PersistenceStub.create_activity(user.id, %{
          name: "YouTube",
          time_source_identifier: "youtube-proj-1",
          multiplier: 2.0,
          effect: :negative,
          activated_at: DateTime.add(DateTime.utc_now(), -10, :day)
        })

      {:ok, _view, html} = live(conn, ~p"/")

      assert html =~ ~s(data-chart="diverging")
      refute html =~ ~s(data-chart="upward")
    end

    test "a drains-only week still renders the diverging chart with visible red columns", %{
      conn: conn,
      user: user
    } do
      {:ok, _drain} =
        PersistenceStub.create_activity(user.id, %{
          name: "YouTube",
          time_source_identifier: "youtube-proj-1",
          multiplier: 2.0,
          effect: :negative,
          activated_at: DateTime.add(DateTime.utc_now(), -10, :day)
        })

      {:ok, _view, html} = live(conn, ~p"/")

      assert html =~ ~s(data-chart="diverging")
      assert html =~ "bg-red-500"
      # drain arm scaled off drain_max, not a zero earn_max -> non-zero height
      refute html =~ ~r/rounded-b overflow-hidden" style="height: 0(\.0)?px/
    end

    test "a User with no tracked time at all sees no chart card", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/")

      refute html =~ "This week by day"
    end

    test "the legend lists each contributing Activity with its signed multiplier", %{
      conn: conn,
      user: user
    } do
      {:ok, _activity} =
        PersistenceStub.create_activity(user.id, %{
          name: "Coding",
          time_source_identifier: "coding-proj-1",
          multiplier: 1.5,
          effect: :positive,
          activated_at: DateTime.add(DateTime.utc_now(), -10, :day)
        })

      {:ok, _view, html} = live(conn, ~p"/")

      assert html =~ ~s(data-role="effect-legend")
      assert html =~ "+1.5×"
    end
  end

  describe "weekly distribution chart — outlier day (#13)" do
    setup do
      on_exit(fn -> TimeSourceStub.stub_entries(nil) end)
      :ok
    end

    # Heights (px) of every earn column, oldest -> newest.
    defp earn_bar_heights(html) do
      ~r/flex-col-reverse rounded-t overflow-hidden[^"]*"\s+style="height:\s*([\d.]+)px"/
      |> Regex.scan(html, capture: :all_but_first)
      |> Enum.map(fn [h] -> String.to_float(h) end)
    end

    defp drain_bar_heights(html) do
      ~r/flex flex-col rounded-b overflow-hidden[^"]*"\s+style="height:\s*([\d.]+)px"/
      |> Regex.scan(html, capture: :all_but_first)
      |> Enum.map(fn [h] -> String.to_float(h) end)
    end

    defp count_substring(haystack, needle),
      do: length(String.split(haystack, needle)) - 1

    test "a dominant earn day is clamped and labelled with its true total, and the other days stay legible",
         %{conn: conn, user: user} do
      {:ok, _} =
        PersistenceStub.create_activity(user.id, %{
          name: "Coding",
          time_source_identifier: "coding-proj-1",
          multiplier: 1.0,
          effect: :positive,
          activated_at: DateTime.add(DateTime.utc_now(), -30, :day)
        })

      now = DateTime.utc_now()

      TimeSourceStub.stub_entries(%{
        "coding-proj-1" => [
          # one 8-hour session, then two ordinary days
          %{start_date: DateTime.add(now, -3, :day), minutes: 480.0, time_entry_id: "big"},
          %{start_date: DateTime.add(now, -2, :day), minutes: 40.0, time_entry_id: "small-a"},
          %{start_date: DateTime.add(now, -1, :day), minutes: 30.0, time_entry_id: "small-b"}
        ]
      })

      {:ok, _view, html} = live(conn, ~p"/")

      assert html =~ ~s(data-chart="upward")

      # Exactly the one outlier column is rendered ragged/faded.
      assert count_substring(html, "chart-bar--clamped-up") == 1

      # Its true total is printed alongside it (480 min -> "8.0 hr").
      assert [_, window] =
               Regex.run(
                 ~r/text-\[10px\] font-semibold leading-none text-gray-600(.{0,200})/s,
                 html
               )

      assert window =~ "8.0"
      assert window =~ "hr"

      heights = earn_bar_heights(html)

      # Nothing overflows the arm...
      assert Enum.all?(heights, &(&1 <= 128.0 + 0.001))
      # ...one column is pinned to the ceiling (the clamped outlier)...
      assert Enum.any?(heights, &(&1 >= 128.0 - 0.001))
      # ...and the two ordinary days render as real bars, not slivers.
      # (ceiling = 1.5 x 40 = 60, so 40 -> ~85px and 30 -> 64px; without the
      # clamp they'd be 40/480 and 30/480 of the arm — ~11px and ~8px.)
      assert Enum.count(heights, &(&1 > 50.0 and &1 < 128.0)) == 2
    end

    test "a dominant drain day is clamped downward instead of overflowing the card", %{
      conn: conn,
      user: user
    } do
      {:ok, _} =
        PersistenceStub.create_activity(user.id, %{
          name: "Coding",
          time_source_identifier: "coding-proj-1",
          multiplier: 1.0,
          effect: :positive,
          activated_at: DateTime.add(DateTime.utc_now(), -30, :day)
        })

      {:ok, _} =
        PersistenceStub.create_activity(user.id, %{
          name: "YouTube",
          time_source_identifier: "youtube-proj-1",
          multiplier: 1.0,
          effect: :negative,
          activated_at: DateTime.add(DateTime.utc_now(), -30, :day)
        })

      now = DateTime.utc_now()

      TimeSourceStub.stub_entries(%{
        "coding-proj-1" => [
          %{start_date: DateTime.add(now, -3, :day), minutes: 40.0, time_entry_id: "e1"},
          %{start_date: DateTime.add(now, -2, :day), minutes: 40.0, time_entry_id: "e2"}
        ],
        "youtube-proj-1" => [
          %{start_date: DateTime.add(now, -1, :day), minutes: 480.0, time_entry_id: "d1"}
        ]
      })

      {:ok, _view, html} = live(conn, ~p"/")

      assert html =~ ~s(data-chart="diverging")
      assert count_substring(html, "chart-bar--clamped-down") == 1

      assert Enum.all?(drain_bar_heights(html), &(&1 <= 128.0 + 0.001))
    end

    test "a flat week draws no clamped column", %{conn: conn, user: user} do
      {:ok, _} =
        PersistenceStub.create_activity(user.id, %{
          name: "Coding",
          time_source_identifier: "coding-proj-1",
          multiplier: 1.0,
          effect: :positive,
          activated_at: DateTime.add(DateTime.utc_now(), -30, :day)
        })

      now = DateTime.utc_now()

      TimeSourceStub.stub_entries(%{
        "coding-proj-1" =>
          for offset <- 1..5 do
            %{
              start_date: DateTime.add(now, -offset, :day),
              minutes: 45.0,
              time_entry_id: "e#{offset}"
            }
          end
      })

      {:ok, _view, html} = live(conn, ~p"/")

      refute html =~ "chart-bar--clamped"
    end
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

  test "shows the day-scoped Playtime hero, with the cumulative Play Balance hidden by default",
       %{
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
    assert html =~ "Drained Today"
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
    # The reconciliation line and the "This Week" block now carry a Drained
    # term (reads 0 for this no-drain fixture) — ADR-0013.
    assert html =~ "Drained"

    # "red means drain" (#16): Drained keeps red, Used moves to amber so
    # spending no longer reads as an error/drain.
    assert html =~ ~r/Drained<\/span>\s*<span class="font-bold text-red-300"/
    assert html =~ ~r/Drained Today<\/span>\s*<span class="font-bold text-red-300"/
    assert html =~ ~r/Used<\/span>\s*<span class="font-bold text-amber-300"/
    assert html =~ ~r/Used Today<\/span>\s*<span class="font-bold text-amber-300"/
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

  describe "Effect toggle and sign-crossing confirmation (#15, ADR-0013)" do
    test "the add form creates a :positive Activity by default, with no confirmation panel", %{
      conn: conn,
      user: user
    } do
      {:ok, view, _html} = live(conn, ~p"/")

      html =
        view
        |> form("form[phx-submit=create_activity]", %{
          "name" => "Coding",
          "time_source_identifier" => "coding-proj-1",
          "multiplier" => "1.5"
        })
        |> render_submit()

      assert html =~ "Added activity Coding!"
      refute html =~ "Draining Activity?"

      assert {:ok, [activity]} = PersistenceStub.list_activities(user.id)
      assert activity.effect == :positive
    end

    test "add form with Effect = drains stashes the write and shows a confirmation panel", %{
      conn: conn,
      user: user
    } do
      {:ok, view, _html} = live(conn, ~p"/")

      html =
        view
        |> form("form[phx-submit=create_activity]", %{
          "name" => "YouTube",
          "time_source_identifier" => "video-proj",
          "multiplier" => "2.0",
          "effect" => "negative"
        })
        |> render_submit()

      assert html =~ "Draining Activity?"
      assert html =~ "YouTube"
      assert {:ok, []} = PersistenceStub.list_activities(user.id)
    end

    test "Confirm on the add-form panel creates the Activity with effect: :negative and flashes",
         %{
           conn: conn,
           user: user
         } do
      {:ok, view, _html} = live(conn, ~p"/")

      view
      |> form("form[phx-submit=create_activity]", %{
        "name" => "YouTube",
        "time_source_identifier" => "video-proj",
        "multiplier" => "2.0",
        "effect" => "negative"
      })
      |> render_submit()

      html = render_click(view, "confirm_pending_activity")

      assert html =~ "Added activity YouTube!"
      refute html =~ "Draining Activity?"

      assert {:ok, [activity]} = PersistenceStub.list_activities(user.id)
      assert activity.effect == :negative
    end

    test "Cancel on the add-form panel creates nothing and dismisses the panel", %{
      conn: conn,
      user: user
    } do
      {:ok, view, _html} = live(conn, ~p"/")

      view
      |> form("form[phx-submit=create_activity]", %{
        "name" => "YouTube",
        "time_source_identifier" => "video-proj",
        "multiplier" => "2.0",
        "effect" => "negative"
      })
      |> render_submit()

      html = render_click(view, "cancel_pending_activity")

      refute html =~ "Draining Activity?"
      assert {:ok, []} = PersistenceStub.list_activities(user.id)
    end

    test "the confirmation panel says nothing is deducted when the project has no tracked time",
         %{
           conn: conn
         } do
      {:ok, view, _html} = live(conn, ~p"/")

      html =
        view
        |> form("form[phx-submit=create_activity]", %{
          "name" => "YouTube",
          "time_source_identifier" => "brand-new-proj",
          "multiplier" => "2.0",
          "effect" => "negative"
        })
        |> render_submit()

      assert html =~ "Draining Activity?"
      assert html =~ "nothing is deducted right now"
    end

    test "a malformed effect param on the add form is treated as :positive", %{
      conn: conn,
      user: user
    } do
      {:ok, view, _html} = live(conn, ~p"/")

      html =
        view
        |> element("form[phx-submit=create_activity]")
        |> render_submit(%{
          "name" => "Coding",
          "time_source_identifier" => "coding-proj-1",
          "multiplier" => "1.0",
          "effect" => "bogus"
        })

      assert html =~ "Added activity Coding!"
      assert {:ok, [activity]} = PersistenceStub.list_activities(user.id)
      assert activity.effect == :positive
    end

    test "the inline edit form shows the Effect control pre-set to the Activity's current effect",
         %{conn: conn, user: user} do
      {:ok, activity} =
        PersistenceStub.create_activity(user.id, %{
          name: "YouTube",
          time_source_identifier: "video-proj",
          multiplier: 2.0,
          effect: :negative,
          activated_at: DateTime.utc_now()
        })

      {:ok, view, _html} = live(conn, ~p"/")

      html = render_click(view, "edit_activity", %{"id" => activity.id})

      assert html =~ ~r/value="negative"[^>]*checked/
    end

    test "editing a positive Activity to drains shows the panel with the projected hit; Confirm persists",
         %{conn: conn, user: user} do
      # activated_at today + an unmapped project id => the stub emits exactly
      # one 20-min entry inside the window, so the projected hit is a known
      # 20.0 * 1.0 = 20.0 min (story 9).
      {:ok, activity} =
        PersistenceStub.create_activity(user.id, %{
          name: "Coding",
          time_source_identifier: "video-proj",
          multiplier: 1.0,
          activated_at: DateTime.utc_now()
        })

      {:ok, view, _html} = live(conn, ~p"/")
      render_click(view, "edit_activity", %{"id" => activity.id})

      html =
        view
        |> form("form[phx-submit=save_activity]", %{
          "name" => "Coding",
          "time_source_identifier" => "video-proj",
          "effect" => "negative"
        })
        |> render_submit()

      assert html =~ "Draining Activity?"

      assert html =~
               ~r{subtract\s*<span[^>]*>20\.0</span>\s*<span[^>]*>min</span>\s*of play time already earned this week}

      assert {:ok, %{effect: :positive}} = PersistenceStub.get_activity(user.id, activity.id)

      html = render_click(view, "confirm_pending_activity")

      assert html =~ "Updated activity Coding!"
      assert {:ok, %{effect: :negative}} = PersistenceStub.get_activity(user.id, activity.id)
    end

    test "Cancel on the edit-form panel leaves the Activity :positive", %{conn: conn, user: user} do
      {:ok, activity} =
        PersistenceStub.create_activity(user.id, %{
          name: "Coding",
          time_source_identifier: "coding-proj-1",
          multiplier: 1.0,
          activated_at: DateTime.add(DateTime.utc_now(), -3, :day)
        })

      {:ok, view, _html} = live(conn, ~p"/")
      render_click(view, "edit_activity", %{"id" => activity.id})

      view
      |> form("form[phx-submit=save_activity]", %{
        "name" => "Coding",
        "time_source_identifier" => "coding-proj-1",
        "effect" => "negative"
      })
      |> render_submit()

      html = render_click(view, "cancel_pending_activity")

      refute html =~ "Draining Activity?"
      assert {:ok, %{effect: :positive}} = PersistenceStub.get_activity(user.id, activity.id)
    end

    test "editing an already-draining Activity's multiplier saves immediately with no panel", %{
      conn: conn,
      user: user
    } do
      {:ok, activity} =
        PersistenceStub.create_activity(user.id, %{
          name: "YouTube",
          time_source_identifier: "video-proj",
          multiplier: 2.0,
          effect: :negative,
          activated_at: DateTime.utc_now()
        })

      {:ok, view, _html} = live(conn, ~p"/")
      render_click(view, "edit_activity", %{"id" => activity.id})
      render_click(view, "increment_multiplier", %{})

      html =
        view
        |> form("form[phx-submit=save_activity]", %{
          "name" => "YouTube",
          "time_source_identifier" => "video-proj",
          "effect" => "negative"
        })
        |> render_submit()

      refute html =~ "Draining Activity?"
      assert html =~ "Updated activity YouTube!"

      assert {:ok, saved} = PersistenceStub.get_activity(user.id, activity.id)
      assert saved.effect == :negative
      assert saved.multiplier == 2.1
    end

    test "editing a draining Activity back to earns saves immediately with no panel", %{
      conn: conn,
      user: user
    } do
      {:ok, activity} =
        PersistenceStub.create_activity(user.id, %{
          name: "YouTube",
          time_source_identifier: "video-proj",
          multiplier: 2.0,
          effect: :negative,
          activated_at: DateTime.utc_now()
        })

      {:ok, view, _html} = live(conn, ~p"/")
      render_click(view, "edit_activity", %{"id" => activity.id})

      html =
        view
        |> form("form[phx-submit=save_activity]", %{
          "name" => "YouTube",
          "time_source_identifier" => "video-proj",
          "effect" => "positive"
        })
        |> render_submit()

      refute html =~ "Draining Activity?"
      assert html =~ "Updated activity YouTube!"
      assert {:ok, %{effect: :positive}} = PersistenceStub.get_activity(user.id, activity.id)
    end
  end

  describe "Source picker (ADR-0014)" do
    # The Stub's list_sources/1 fixture (see TimeSource.Stub): a 2-level tree
    # whose leaf ids keep rate-matching prefixes. "Development → App" is id
    # "coding-app"; "Learning → Elixir" is "learning-elixir".
    setup %{user: user} do
      {:ok, _integration} =
        Accounts.upsert_integration(user, %{
          provider: "timing",
          credentials: %{"api_key" => "test-key"}
        })

      :ok
    end

    defp open_dashboard(conn) do
      {:ok, view, _html} = live(conn, ~p"/")
      render_async(view)
      view
    end

    test "with no integration the picker is a plain manual id field, no dropdown" do
      {:ok, other} = Accounts.create_user()
      {:ok, other} = Accounts.update_timezone(other, "Pacific/Auckland")
      conn = log_in_user(Phoenix.ConnTest.build_conn(), other)

      {:ok, _view, html} = live(conn, ~p"/")

      assert html =~ ~s(placeholder="paste a Source ID")
      refute html =~ "Search Sources"
    end

    test "once sources load, the add form's picker filters and a pick stores the bare id + label snapshot",
         %{conn: conn, user: user} do
      view = open_dashboard(conn)

      assert render(view) =~ ~s(placeholder="Search Sources…")

      view
      |> element("#source-picker-new input[phx-keyup=filter]")
      |> render_keyup(%{"key" => "p", "value" => "app"})

      html = render(view)
      assert html =~ "App"
      refute html =~ ">Elixir<"

      view
      |> element(~s(#source-picker-new button[phx-value-id="coding-app"]))
      |> render_click()

      view
      |> form("form[phx-submit=create_activity]", %{"name" => "My coding", "multiplier" => "1.5"})
      |> render_submit()

      assert {:ok, [activity]} = PersistenceStub.list_activities(user.id)
      assert activity.time_source_identifier == "coding-app"
      assert activity.time_source_label == "Development → App"
      assert activity.name == "My coding"
    end

    test "a blank Name on the add form is prefilled with the picked Source's leaf title", %{
      conn: conn,
      user: user
    } do
      view = open_dashboard(conn)

      view
      |> element("#source-picker-new input[phx-keyup=filter]")
      |> render_keyup(%{"key" => "x", "value" => "elixir"})

      view
      |> element(~s(#source-picker-new button[phx-value-id="learning-elixir"]))
      |> render_click()

      view
      |> form("form[phx-submit=create_activity]", %{"name" => "", "multiplier" => "1.0"})
      |> render_submit()

      assert {:ok, [activity]} = PersistenceStub.list_activities(user.id)
      assert activity.name == "Elixir"
      assert activity.time_source_label == "Learning → Elixir"
    end

    test "a zero-match filter offers the manual-entry escape hatch", %{conn: conn} do
      view = open_dashboard(conn)

      view
      |> element("#source-picker-new input[phx-keyup=filter]")
      |> render_keyup(%{"key" => "z", "value" => "zzzznope"})

      assert render(view) =~ "No match"
    end

    test "editing an Activity whose stored id matches a Source preselects the picker, and Name is untouched",
         %{conn: conn, user: user} do
      {:ok, activity} =
        PersistenceStub.create_activity(user.id, %{
          name: "Keep this name",
          time_source_identifier: "coding-app",
          time_source_label: "Development → App",
          multiplier: 1.0,
          activated_at: DateTime.add(DateTime.utc_now(), -3, :day)
        })

      view = open_dashboard(conn)
      html = render_click(view, "edit_activity", %{"id" => activity.id})

      assert html =~ ~s(value="Development → App")

      view
      |> form("form[phx-submit=save_activity]", %{"name" => "Keep this name"})
      |> render_submit()

      assert {:ok, saved} = PersistenceStub.get_activity(user.id, activity.id)
      assert saved.name == "Keep this name"
      assert saved.time_source_label == "Development → App"
    end

    test "editing an Activity whose stored id matches nothing opens the picker in manual mode showing that id",
         %{conn: conn, user: user} do
      {:ok, activity} =
        PersistenceStub.create_activity(user.id, %{
          name: "Legacy",
          time_source_identifier: "some-old-id",
          multiplier: 1.0,
          activated_at: DateTime.add(DateTime.utc_now(), -3, :day)
        })

      view = open_dashboard(conn)
      html = render_click(view, "edit_activity", %{"id" => activity.id})

      assert html =~ ~s(value="some-old-id")
      assert html =~ ~s(placeholder="paste a Source ID")
    end

    test "a manual-mode edit that doesn't retype the id keeps the stored label snapshot (ADR-0014)",
         %{conn: conn, user: user} do
      {:ok, activity} =
        PersistenceStub.create_activity(user.id, %{
          name: "Renamed upstream",
          time_source_identifier: "id-since-renamed",
          time_source_label: "Old Parent → Old Leaf",
          multiplier: 1.0,
          activated_at: DateTime.add(DateTime.utc_now(), -3, :day)
        })

      view = open_dashboard(conn)
      render_click(view, "edit_activity", %{"id" => activity.id})

      # touch only the multiplier, then save — the Source field is untouched
      render_click(view, "increment_multiplier", %{})

      view
      |> form("form[phx-submit=save_activity]", %{"name" => "Renamed upstream"})
      |> render_submit()

      assert {:ok, saved} = PersistenceStub.get_activity(user.id, activity.id)
      assert saved.time_source_label == "Old Parent → Old Leaf"
      assert saved.time_source_identifier == "id-since-renamed"
    end

    test "the Add form can't be submitted in picker mode with nothing selected", %{conn: conn} do
      view = open_dashboard(conn)

      html =
        view
        |> form("form[phx-submit=create_activity]", %{"name" => "No source", "multiplier" => "1.0"})
        |> render_submit()

      assert html =~ "Pick a Source"
    end

    test "after a pick, re-opening the dropdown still shows the source (the '→' path isn't a dead filter)",
         %{conn: conn} do
      view = open_dashboard(conn)

      view
      |> element("#source-picker-new input[phx-keyup=filter]")
      |> render_keyup(%{"key" => "p", "value" => "app"})

      view
      |> element(~s(#source-picker-new button[phx-value-id="coding-app"]))
      |> render_click()

      # the field now holds "Development → App"; a keyup with that value
      # (as happens on the next focus/keystroke) must not wipe the list
      html =
        view
        |> element("#source-picker-new input[phx-keyup=filter]")
        |> render_keyup(%{"key" => "p", "value" => "Development → App"})

      assert html =~ ">App<"
      refute html =~ "No match"
    end

    test "the Activity card shows the label snapshot, or the bare id when there's no label", %{
      conn: conn,
      user: user
    } do
      {:ok, _labelled} =
        PersistenceStub.create_activity(user.id, %{
          name: "Labelled",
          time_source_identifier: "coding-app",
          time_source_label: "Development → App",
          multiplier: 1.0,
          activated_at: DateTime.add(DateTime.utc_now(), -3, :day)
        })

      {:ok, _bare} =
        PersistenceStub.create_activity(user.id, %{
          name: "Bare",
          time_source_identifier: "raw-id-only",
          multiplier: 1.0,
          activated_at: DateTime.add(DateTime.utc_now(), -3, :day)
        })

      {:ok, _view, html} = live(conn, ~p"/")

      assert html =~ "Development → App"
      assert html =~ "raw-id-only"
    end
  end

  describe "arrival banner (email linking, ADR-0015)" do
    test "shows for a User with 0 Activities and no Integration", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/")

      assert html =~ "Continue with email"
      assert html =~ "I&#39;m new — hide this"
    end

    test "does not show once the User has an Activity", %{conn: conn, user: user} do
      {:ok, _activity} =
        PersistenceStub.create_activity(user.id, %{
          name: "Coding",
          time_source_identifier: "coding-proj-1",
          multiplier: 1.0,
          activated_at: DateTime.utc_now()
        })

      {:ok, _view, html} = live(conn, ~p"/")

      refute html =~ "Continue with email"
    end

    test "does not show once dismissed", %{conn: conn, user: user} do
      {:ok, _user} = Accounts.dismiss_arrival_banner(user)
      conn = log_in_user(conn, user)

      {:ok, _view, html} = live(conn, ~p"/")

      refute html =~ "Continue with email"
    end

    test "dismissing persists and hides the banner", %{conn: conn, user: user} do
      {:ok, view, html} = live(conn, ~p"/")
      assert html =~ "Continue with email"

      html = render_click(view, "dismiss_arrival_banner", %{})

      refute html =~ "Continue with email"
      assert Accounts.get_user(user.id).arrival_banner_dismissed == true
    end
  end
end
