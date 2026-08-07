defmodule TimingPlayTime.PlayBalanceTest do
  # async: false — see comment in activity_manager_test.exs.
  use ExUnit.Case, async: false

  alias TimingPlayTime.PlayBalance
  alias TimingPlayTime.Plugins.Persistence.Stub, as: PersistenceStub

  setup do
    :ok = PersistenceStub.clear_all_state()
    %{user: %{id: Ecto.UUID.generate(), timezone: "Pacific/Auckland"}}
  end

  describe "compute/1" do
    test "returns zero balance when no activities, manual sync, or playtime used", %{user: user} do
      assert {:ok, balance} = PlayBalance.compute(user)
      assert balance.total == 0.0
      assert balance.timing_derived_total == 0.0
      assert balance.manual_sync_total == 0.0
      assert balance.playtime_used_total == 0.0
    end

    test "calculates timing-derived total from active activities", %{user: user} do
      # Create activities with different multipliers
      {:ok, _activity1} =
        PersistenceStub.create_activity(user.id, %{
          name: "Coding",
          time_source_identifier: "coding-proj-1",
          multiplier: 1.5,
          activated_at: DateTime.add(DateTime.utc_now(), -7, :day)
        })

      {:ok, _activity2} =
        PersistenceStub.create_activity(user.id, %{
          name: "Learning",
          time_source_identifier: "learning-proj-1",
          multiplier: 2.0,
          activated_at: DateTime.add(DateTime.utc_now(), -3, :day)
        })

      # Stub returns: coding ~45min/day * 7 days = 315, learning ~42min/day * 3 days = 126
      # With multipliers: 315 * 1.5 = 472.5, 126 * 2.0 = 252
      # Total timing-derived = 724.5

      assert {:ok, balance} = PlayBalance.compute(user)
      assert_in_delta balance.timing_derived_total, 724.5, 0.1
      assert balance.manual_sync_total == 0.0
      assert balance.playtime_used_total == 0.0
      assert_in_delta balance.total, 724.5, 0.1
    end

    test "includes manual sync total in balance", %{user: user} do
      {:ok, _} = PersistenceStub.set_manual_sync_total(user.id, 150.0)

      assert {:ok, balance} = PlayBalance.compute(user)
      assert balance.manual_sync_total == 150.0
      assert_in_delta balance.total, 150.0, 0.1
    end

    test "subtracts playtime used from balance", %{user: user} do
      # Log some playtime usage
      {:ok, _} = PersistenceStub.log_playtime_used(user.id, 30.0, DateTime.utc_now())
      {:ok, _} = PersistenceStub.log_playtime_used(user.id, 15.0, DateTime.utc_now())

      assert {:ok, balance} = PlayBalance.compute(user)
      assert balance.playtime_used_total == 45.0
      assert_in_delta balance.total, -45.0, 0.1
    end

    test "computes full balance with all components", %{user: user} do
      # Create activity
      {:ok, _activity} =
        PersistenceStub.create_activity(user.id, %{
          name: "Exercise",
          time_source_identifier: "exercise-proj-1",
          multiplier: 1.0,
          activated_at: DateTime.add(DateTime.utc_now(), -5, :day)
        })

      # Set manual sync
      {:ok, _} = PersistenceStub.set_manual_sync_total(user.id, 100.0)

      # Log playtime used
      {:ok, _} = PersistenceStub.log_playtime_used(user.id, 25.0, DateTime.utc_now())
      {:ok, _} = PersistenceStub.log_playtime_used(user.id, 10.0, DateTime.utc_now())

      # Stub returns: exercise ~36min/day * 5 days = 180
      # With multiplier: 180 * 1.0 = 180
      # Balance = 180 (timing) + 100 (manual) - 35 (used) = 245

      assert {:ok, balance} = PlayBalance.compute(user)
      assert_in_delta balance.timing_derived_total, 180.0, 0.1
      assert balance.manual_sync_total == 100.0
      assert balance.playtime_used_total == 35.0
      assert_in_delta balance.total, 245.0, 0.1
    end

    test "handles negative balance when playtime used exceeds earned", %{user: user} do
      {:ok, _} = PersistenceStub.set_manual_sync_total(user.id, 50.0)
      {:ok, _} = PersistenceStub.log_playtime_used(user.id, 80.0, DateTime.utc_now())

      assert {:ok, balance} = PlayBalance.compute(user)
      assert_in_delta balance.total, -30.0, 0.1
    end

    test "is isolated per user", %{user: user} do
      other_user_id = Ecto.UUID.generate()
      {:ok, _} = PersistenceStub.set_manual_sync_total(other_user_id, 999.0)

      assert {:ok, balance} = PlayBalance.compute(user)
      assert balance.total == 0.0
    end

    test "fetches every activity's elapsed minutes in a single call to the plural fetcher", %{
      user: user
    } do
      {:ok, _} =
        PersistenceStub.create_activity(user.id, %{
          name: "Coding",
          time_source_identifier: "coding-proj-1",
          multiplier: 1.0,
          activated_at: DateTime.add(DateTime.utc_now(), -1, :day)
        })

      {:ok, _} =
        PersistenceStub.create_activity(user.id, %{
          name: "Learning",
          time_source_identifier: "learning-proj-1",
          multiplier: 1.0,
          activated_at: DateTime.add(DateTime.utc_now(), -1, :day)
        })

      test_pid = self()

      get_elapsed_minutes = fn activities, opts ->
        send(test_pid, :fetch_called)
        TimingPlayTime.Plugins.TimeSource.Stub.get_elapsed_minutes(activities, opts)
      end

      assert {:ok, _balance} = PlayBalance.compute(user, [], get_elapsed_minutes)

      assert_received :fetch_called
      refute_received :fetch_called
    end

    test "zeroes the timing-derived total (rather than erroring) when the fetcher fails", %{
      user: user
    } do
      {:ok, _} =
        PersistenceStub.create_activity(user.id, %{
          name: "Coding",
          time_source_identifier: "coding-proj-1",
          multiplier: 1.0,
          activated_at: DateTime.add(DateTime.utc_now(), -1, :day)
        })

      {:ok, _} = PersistenceStub.set_manual_sync_total(user.id, 5.0)

      get_elapsed_minutes = fn _activities, _opts -> {:error, :boom} end

      assert {:ok, balance} = PlayBalance.compute(user, [], get_elapsed_minutes)
      assert balance.timing_derived_total == 0.0
      assert balance.total == 5.0
    end
  end

  describe "today_activity_minutes/2" do
    test "clamps to the local start-of-day when the activity was activated on an earlier day", %{
      user: user
    } do
      {:ok, activity} =
        PersistenceStub.create_activity(user.id, %{
          name: "Coding",
          time_source_identifier: "coding-proj-1",
          multiplier: 2.0,
          activated_at: ~U[2026-07-20 00:00:00Z]
        })

      # Local (Pacific/Auckland, NZST/UTC+12) start of today is 2026-07-24T12:00:00Z;
      # `now` is 22h later, so elapsed today = 22/24 days.
      now = ~U[2026-07-25 10:00:00Z]

      assert {:ok, %{minutes: minutes, play_minutes: play_minutes}} =
               PlayBalance.today_activity_minutes(activity, user, now)

      assert_in_delta minutes, 45.0 * (22 / 24), 0.01
      assert_in_delta play_minutes, minutes * 2.0, 0.001
    end

    test "still counts from local start-of-day when the activity was activated later today", %{
      user: user
    } do
      {:ok, activity} =
        PersistenceStub.create_activity(user.id, %{
          name: "Learning",
          time_source_identifier: "learning-proj-1",
          multiplier: 1.0,
          # Same local calendar day as `now` (Pacific/Auckland), but after
          # local start-of-today (2026-07-24T12:00:00Z) — activation happened
          # partway through today, not at midnight.
          activated_at: ~U[2026-07-25 01:00:00Z]
        })

      # Local start of today is still 2026-07-24T12:00:00Z; `from` must not
      # clamp forward to activated_at, so elapsed today = 22/24 days, not 9/24
      # — matching the Timing-Derived Earned Total's day-boundary parity.
      now = ~U[2026-07-25 10:00:00Z]

      assert {:ok, %{minutes: minutes, play_minutes: play_minutes}} =
               PlayBalance.today_activity_minutes(activity, user, now)

      assert_in_delta minutes, 42.0 * (22 / 24), 0.01
      assert_in_delta play_minutes, minutes, 0.001
    end
  end

  describe "week_activity_minutes/3" do
    test "sums an activity's entries within the last 7 days, applying its multiplier", %{user: user} do
      now = ~U[2026-07-25 10:00:00Z]

      {:ok, activity} =
        PersistenceStub.create_activity(user.id, %{
          name: "Coding",
          time_source_identifier: "coding-proj-1",
          multiplier: 2.0,
          activated_at: ~U[2026-01-01 00:00:00Z]
        })

      list_entries = fn _activities, _opts ->
        {:ok,
         %{
           "coding-proj-1" => [
             %{start_date: DateTime.add(now, -3, :day), minutes: 30.0},
             %{start_date: DateTime.add(now, -1, :day), minutes: 10.0}
           ]
         }}
      end

      assert {:ok, %{minutes: 40.0, play_minutes: 80.0}} =
               PlayBalance.week_activity_minutes(activity, now, list_entries)
    end

    test "excludes an entry more than 7 days old (the exact rolling Entry Expiry Window cutoff)", %{
      user: user
    } do
      now = ~U[2026-07-25 10:00:00Z]

      {:ok, activity} =
        PersistenceStub.create_activity(user.id, %{
          name: "Coding",
          time_source_identifier: "coding-proj-1",
          multiplier: 1.0,
          activated_at: ~U[2026-01-01 00:00:00Z]
        })

      list_entries = fn _activities, _opts ->
        {:ok,
         %{
           "coding-proj-1" => [
             %{start_date: DateTime.add(now, -7 * 24 * 60 - 1, :minute), minutes: 100.0},
             %{start_date: DateTime.add(now, -1, :day), minutes: 10.0}
           ]
         }}
      end

      assert {:ok, %{minutes: 10.0, play_minutes: 10.0}} =
               PlayBalance.week_activity_minutes(activity, now, list_entries)
    end

    test "requests the fetch itself bounded to the window's start", %{user: user} do
      now = ~U[2026-07-25 10:00:00Z]
      test_pid = self()

      {:ok, activity} =
        PersistenceStub.create_activity(user.id, %{
          name: "Coding",
          time_source_identifier: "coding-proj-1",
          multiplier: 1.0,
          activated_at: ~U[2026-01-01 00:00:00Z]
        })

      list_entries = fn _activities, opts ->
        send(test_pid, {:list_entries_opts, opts})
        {:ok, %{}}
      end

      assert {:ok, _} = PlayBalance.week_activity_minutes(activity, now, list_entries)

      assert_received {:list_entries_opts, opts}
      assert Keyword.get(opts, :from) == DateTime.add(now, -7, :day)
    end

    test "returns zero for an activity with no entries", %{user: user} do
      {:ok, activity} =
        PersistenceStub.create_activity(user.id, %{
          name: "Coding",
          time_source_identifier: "coding-proj-1",
          multiplier: 1.0,
          activated_at: ~U[2026-01-01 00:00:00Z]
        })

      list_entries = fn _activities, _opts -> {:ok, %{}} end

      assert {:ok, %{minutes: minutes, play_minutes: play_minutes}} =
               PlayBalance.week_activity_minutes(activity, DateTime.utc_now(), list_entries)

      assert minutes == 0.0
      assert play_minutes == 0.0
    end
  end

  describe "compute_today/4's week_earned/week_used reconciliation" do
    test "playtime == week_earned - week_used + pushscroll_balance, exactly, even when a spend can't reach an entry logged later the same day",
         %{user: user} do
      # Local start of today (Pacific/Auckland) is 2026-07-24T12:00:00Z.
      now = ~U[2026-07-25 10:00:00Z]

      {:ok, _} =
        PersistenceStub.create_activity(user.id, %{
          name: "Coding",
          time_source_identifier: "coding-proj-1",
          multiplier: 1.0,
          activated_at: ~U[2026-01-01 00:00:00Z]
        })

      {:ok, _} = PersistenceStub.set_manual_sync_total(user.id, 5.0)

      # A spend at 08:00, then an entry logged at 09:00 (after the spend) —
      # the spend can't reach it (causality), so it's untouched: today_net
      # ends up > 0 even though used_today (50) exceeds earned_today (30).
      # This is exactly the scenario that makes `today_net + reserve` hard
      # to eyeball against `earned_today`/`used_today` — week_earned/
      # week_used sidesteps it entirely.
      list_entries = fn _activities, _opts ->
        {:ok, %{"coding-proj-1" => [%{start_date: ~U[2026-07-25 09:00:00Z], minutes: 30.0}]}}
      end

      {:ok, _} = PersistenceStub.log_playtime_used(user.id, 50.0, ~U[2026-07-25 08:00:00Z])

      assert {:ok, today} = PlayBalance.compute_today(user, now, [], list_entries)

      assert today.earned_today == 30.0
      assert today.used_today == 50.0
      # The 30.0 entry (logged 10:00) is entirely untouched by the 08:00
      # spend, so it survives whole in today_net rather than flooring at 0.
      assert today.today_net == 30.0
      # The 08:00 spend had nothing to draw on at all (no entry existed yet
      # that day, and no reserve) — it's pure deficit, absorbed by reserve.
      assert today.reserve == -45.0
      assert_in_delta today.playtime, today.week_earned - today.week_used + today.pushscroll_balance, 0.0001
    end

    test "the identity holds when overflow drains reserve across several activities and days", %{
      user: user
    } do
      now = ~U[2026-07-25 10:00:00Z]

      {:ok, _} =
        PersistenceStub.create_activity(user.id, %{
          name: "Coding",
          time_source_identifier: "coding-proj-1",
          multiplier: 2.0,
          activated_at: ~U[2026-01-01 00:00:00Z]
        })

      {:ok, _} =
        PersistenceStub.create_activity(user.id, %{
          name: "Learning",
          time_source_identifier: "learning-proj-1",
          multiplier: 1.0,
          activated_at: ~U[2026-01-01 00:00:00Z]
        })

      {:ok, _} = PersistenceStub.set_manual_sync_total(user.id, 12.0)

      list_entries = fn _activities, _opts ->
        {:ok,
         %{
           "coding-proj-1" => [
             %{start_date: DateTime.add(now, -5, :day), minutes: 20.0},
             %{start_date: now, minutes: 15.0}
           ],
           "learning-proj-1" => [%{start_date: DateTime.add(now, -2, :day), minutes: 40.0}]
         }}
      end

      {:ok, _} = PersistenceStub.log_playtime_used(user.id, 10.0, DateTime.add(now, -4, :day))
      {:ok, _} = PersistenceStub.log_playtime_used(user.id, 55.0, now)

      assert {:ok, today} = PlayBalance.compute_today(user, now, [], list_entries)

      assert_in_delta today.playtime, today.week_earned - today.week_used + today.pushscroll_balance, 0.0001
    end
  end

  describe "compute_today/4" do
    test "sums today's earned Play Minutes and today's used minutes; folds Pushscroll Balance into Reserve",
         %{user: user} do
      {:ok, _activity} =
        PersistenceStub.create_activity(user.id, %{
          name: "Coding",
          time_source_identifier: "coding-proj-1",
          multiplier: 2.0,
          activated_at: ~U[2026-07-01 00:00:00Z]
        })

      {:ok, _} = PersistenceStub.set_manual_sync_total(user.id, 10.0)

      # Local start of today is 2026-07-24T12:00:00Z.
      {:ok, _} = PersistenceStub.log_playtime_used(user.id, 30.0, ~U[2026-07-23 09:00:00Z])
      {:ok, _} = PersistenceStub.log_playtime_used(user.id, 15.0, ~U[2026-07-25 05:00:00Z])

      now = ~U[2026-07-25 10:00:00Z]

      # Raw (pre-multiplier) Timing minutes: a reserve entry (5 days back,
      # within the 7-day Entry Expiry Window) and a today entry.
      list_entries = fn _activities, _opts ->
        {:ok,
         %{
           "coding-proj-1" => [
             %{start_date: ~U[2026-07-20 09:00:00Z], minutes: 50.0},
             %{start_date: ~U[2026-07-25 01:00:00Z], minutes: 10.0}
           ]
         }}
      end

      assert {:ok, today} = PlayBalance.compute_today(user, now, [], list_entries)

      # Today's entry: 10.0 * 2.0 multiplier = 20.0, unaffected by consumption.
      assert today.earned_today == 20.0
      assert today.used_today == 15.0
      assert today.pushscroll_balance == 10.0
      # Today's own entry (20.0) minus today's own spend (15.0) — the
      # earlier (07-23) spend can't touch it (didn't exist yet then).
      assert today.today_net == 5.0
      # Reserve entry (100.0) minus the 07-23 spend (30.0, drawn from it as
      # overflow, since no entries existed on 07-23 itself) plus Pushscroll
      # Balance (10.0).
      assert today.reserve == 80.0
      assert today.playtime == 85.0
    end

    test "zeroes every activity's totals for the computation when the fetcher errors (ADR-0008's shared failure blast radius)",
         %{user: user} do
      {:ok, _activity} =
        PersistenceStub.create_activity(user.id, %{
          name: "Coding",
          time_source_identifier: "coding-proj-1",
          multiplier: 1.0,
          activated_at: ~U[2026-07-01 00:00:00Z]
        })

      {:ok, _} = PersistenceStub.set_manual_sync_total(user.id, 10.0)

      now = ~U[2026-07-25 10:00:00Z]
      list_entries = fn _activities, _opts -> {:error, :boom} end

      assert {:ok, today} = PlayBalance.compute_today(user, now, [], list_entries)

      assert today.earned_today == 0.0
      assert today.reserve == 10.0
    end

    test "floors today_net at zero and spills the deficit into reserve when Playtime Used exceeds everything earned so far",
         %{user: user} do
      {:ok, _} = PersistenceStub.set_manual_sync_total(user.id, 5.0)
      {:ok, _} = PersistenceStub.log_playtime_used(user.id, 100.0, ~U[2026-07-25 09:00:00Z])

      now = ~U[2026-07-25 10:00:00Z]

      assert {:ok, today} = PlayBalance.compute_today(user, now)

      assert today.earned_today == 0.0
      assert today.used_today == 100.0
      assert today.today_net == 0.0
      assert today.reserve == -95.0
      assert today.playtime == -95.0
    end

    test "reserve goes negative when prior-days' Playtime Used exceeds prior-days' earnings, independent of today's activity",
         %{user: user} do
      # No Activities at all, so earned is 0.0 both cumulatively and today —
      # isolates Reserve's sign to just the prior-days Playtime Used below.
      {:ok, _} = PersistenceStub.log_playtime_used(user.id, 50.0, ~U[2026-07-24 11:00:00Z])

      now = ~U[2026-07-25 10:00:00Z]

      assert {:ok, today} = PlayBalance.compute_today(user, now)

      assert today.today_net == 0.0
      assert today.reserve == -50.0
      assert today.playtime == -50.0
    end

    test "excludes an entry more than 7 days old from Reserve (Entry Expiry Window)", %{user: user} do
      now = ~U[2026-07-25 10:00:00Z]

      # Exactly on the boundary: 7 days and 1 minute before `now`, so just
      # outside the window (an exact rolling cutoff, not calendar-aligned).
      list_entries = fn _activities, _opts ->
        {:ok,
         %{
           "coding-proj-1" => [
             %{start_date: DateTime.add(now, -7 * 24 * 60 - 1, :minute), minutes: 100.0}
           ]
         }}
      end

      {:ok, _} =
        PersistenceStub.create_activity(user.id, %{
          name: "Coding",
          time_source_identifier: "coding-proj-1",
          multiplier: 1.0,
          activated_at: ~U[2026-01-01 00:00:00Z]
        })

      assert {:ok, today} = PlayBalance.compute_today(user, now, [], list_entries)

      assert today.reserve == 0.0
      assert today.playtime == 0.0
    end

    test "an entry's already-spent minutes are never double-counted against a User once it expires",
         %{user: user} do
      now = ~U[2026-07-25 10:00:00Z]

      # Fully spent (100 earned, 100 used) 8 days ago — outside the window,
      # but its consumption shouldn't leave any residual debt behind either.
      list_entries = fn _activities, _opts ->
        {:ok,
         %{"coding-proj-1" => [%{start_date: DateTime.add(now, -8, :day), minutes: 100.0}]}}
      end

      {:ok, _} =
        PersistenceStub.create_activity(user.id, %{
          name: "Coding",
          time_source_identifier: "coding-proj-1",
          multiplier: 1.0,
          activated_at: ~U[2026-01-01 00:00:00Z]
        })

      {:ok, _} = PersistenceStub.log_playtime_used(user.id, 100.0, DateTime.add(now, -8, :day))

      assert {:ok, today} = PlayBalance.compute_today(user, now, [], list_entries)

      assert today.reserve == 0.0
      assert today.playtime == 0.0
    end

    test "a recent spend visibly draws down Reserve, rather than being silently absorbed by an ancient already-expired backlog",
         %{user: user} do
      now = ~U[2026-07-25 10:00:00Z]

      # A large, long-unspent backlog from months ago (outside the window,
      # already invisible) plus one small recent (in-window) reserve entry.
      # Oldest-first FIFO must not let a spend hide inside the invisible
      # backlog forever — the caller is responsible for not handing the
      # ledger that backlog at all (EntryLedger's moduledoc).
      list_entries = fn _activities, _opts ->
        {:ok,
         %{
           "coding-proj-1" => [
             %{start_date: DateTime.add(now, -90, :day), minutes: 10_000.0},
             %{start_date: DateTime.add(now, -3, :day), minutes: 50.0}
           ]
         }}
      end

      {:ok, _} =
        PersistenceStub.create_activity(user.id, %{
          name: "Coding",
          time_source_identifier: "coding-proj-1",
          multiplier: 1.0,
          activated_at: ~U[2026-01-01 00:00:00Z]
        })

      {:ok, _} = PersistenceStub.log_playtime_used(user.id, 30.0, now)

      assert {:ok, today} = PlayBalance.compute_today(user, now, [], list_entries)

      # The 3-day-old reserve entry (50.0) must absorb the spend — the
      # 90-day-old entry is outside the window and unreachable.
      assert today.reserve == 20.0
      assert today.playtime == 20.0
    end

    test "bounds the entries fetch to the Entry Expiry Window's start, not unbounded all-time",
         %{user: user} do
      now = ~U[2026-07-25 10:00:00Z]
      test_pid = self()

      list_entries = fn _activities, opts ->
        send(test_pid, {:list_entries_opts, opts})
        {:ok, %{}}
      end

      {:ok, _} =
        PersistenceStub.create_activity(user.id, %{
          name: "Coding",
          time_source_identifier: "coding-proj-1",
          multiplier: 1.0,
          activated_at: ~U[2026-01-01 00:00:00Z]
        })

      assert {:ok, _today} = PlayBalance.compute_today(user, now, [], list_entries)

      assert_received {:list_entries_opts, opts}
      assert Keyword.get(opts, :from) == DateTime.add(now, -7, :day)
    end
  end
end
