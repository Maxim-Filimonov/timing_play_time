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
  end

  describe "get_totals/3" do
    test "fetches every given activity's elapsed minutes in a single call to the plural fetcher" do
      test_pid = self()

      activities = [
        %{time_source_identifier: "coding-proj-1", activated_at: DateTime.utc_now()},
        %{time_source_identifier: "learning-proj-1", activated_at: DateTime.utc_now()}
      ]

      get_elapsed_minutes = fn given_activities, opts ->
        send(test_pid, :fetch_called)
        TimingPlayTime.Plugins.TimeSource.Stub.get_elapsed_minutes(given_activities, opts)
      end

      assert %{"coding-proj-1" => _, "learning-proj-1" => _} =
               PlayBalance.get_totals(activities, [], get_elapsed_minutes)

      assert_received :fetch_called
      refute_received :fetch_called
    end

    test "returns an empty map (rather than erroring) when the fetcher fails" do
      get_elapsed_minutes = fn _activities, _opts -> {:error, :boom} end

      assert PlayBalance.get_totals(
               [%{time_source_identifier: "coding-proj-1"}],
               [],
               get_elapsed_minutes
             ) ==
               %{}
    end
  end

  describe "activity_today_minutes/2" do
    test "looks up the activity's :today total from a pre-fetched totals map and applies its multiplier" do
      activity = %{time_source_identifier: "coding-proj-1", multiplier: 2.0, effect: :positive}
      totals = %{"coding-proj-1" => %{cumulative: 999.0, today: 15.0}}

      assert PlayBalance.activity_today_minutes(totals, activity) ==
               %{minutes: 15.0, play_minutes: 30.0}
    end

    test "returns zero when the activity's identifier isn't present in totals" do
      activity = %{time_source_identifier: "coding-proj-1", multiplier: 2.0, effect: :positive}

      assert PlayBalance.activity_today_minutes(%{}, activity) ==
               %{minutes: 0.0, play_minutes: 0.0}
    end

    test "a Draining Activity's play_minutes is negative — its magnitude times -1 (ADR-0013)" do
      drain = %{time_source_identifier: "youtube-proj-1", multiplier: 2.0, effect: :negative}
      totals = %{"youtube-proj-1" => %{cumulative: 999.0, today: 15.0}}

      assert PlayBalance.activity_today_minutes(totals, drain) ==
               %{minutes: 15.0, play_minutes: -30.0}
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
    test "sums an activity's entries within the last 7 days, applying its multiplier", %{
      user: user
    } do
      now = ~U[2026-07-25 10:00:00Z]

      {:ok, activity} =
        PersistenceStub.create_activity(user.id, %{
          name: "Coding",
          time_source_identifier: "coding-proj-1",
          multiplier: 2.0,
          activated_at: ~U[2026-01-01 00:00:00Z]
        })

      raw_entries = %{
        "coding-proj-1" => [
          %{start_date: DateTime.add(now, -3, :day), minutes: 30.0},
          %{start_date: DateTime.add(now, -1, :day), minutes: 10.0}
        ]
      }

      assert {:ok, %{minutes: 40.0, play_minutes: 80.0}} =
               PlayBalance.week_activity_minutes(activity, now, [], raw_entries)
    end

    test "excludes an entry more than 7 days old (the exact rolling Entry Expiry Window cutoff)",
         %{
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

      raw_entries = %{
        "coding-proj-1" => [
          %{start_date: DateTime.add(now, -7 * 24 * 60 - 1, :minute), minutes: 100.0},
          %{start_date: DateTime.add(now, -1, :day), minutes: 10.0}
        ]
      }

      assert {:ok, %{minutes: 10.0, play_minutes: 10.0}} =
               PlayBalance.week_activity_minutes(activity, now, [], raw_entries)
    end

    test "returns zero for an activity with no entries", %{user: user} do
      {:ok, activity} =
        PersistenceStub.create_activity(user.id, %{
          name: "Coding",
          time_source_identifier: "coding-proj-1",
          multiplier: 1.0,
          activated_at: ~U[2026-01-01 00:00:00Z]
        })

      assert {:ok, %{minutes: minutes, play_minutes: play_minutes}} =
               PlayBalance.week_activity_minutes(activity, DateTime.utc_now(), [], %{})

      assert minutes == 0.0
      assert play_minutes == 0.0
    end

    test "accepts a provisional Activity map with no :id and returns the expected signed play_minutes" do
      # The confirmation panel in #15 calls this with a map that does not
      # exist in the DB yet, to preview the retroactive drain hit.
      now = ~U[2026-07-25 10:00:00Z]

      provisional = %{
        time_source_identifier: "youtube-proj-1",
        multiplier: 2.0,
        effect: :negative
      }

      raw_entries = %{
        "youtube-proj-1" => [
          %{start_date: DateTime.add(now, -3, :day), minutes: 30.0},
          %{start_date: DateTime.add(now, -1, :day), minutes: 10.0}
        ]
      }

      assert {:ok, %{minutes: 40.0, play_minutes: -80.0}} =
               PlayBalance.week_activity_minutes(provisional, now, [], raw_entries)
    end

    test "a Draining Activity's weekly play_minutes is negative (ADR-0013)", %{user: user} do
      now = ~U[2026-07-25 10:00:00Z]

      {:ok, drain} =
        PersistenceStub.create_activity(user.id, %{
          name: "YouTube",
          time_source_identifier: "youtube-proj-1",
          multiplier: 2.0,
          effect: :negative,
          activated_at: ~U[2026-01-01 00:00:00Z]
        })

      raw_entries = %{
        "youtube-proj-1" => [%{start_date: DateTime.add(now, -1, :day), minutes: 30.0}]
      }

      assert {:ok, %{minutes: 30.0, play_minutes: -60.0}} =
               PlayBalance.week_activity_minutes(drain, now, [], raw_entries)
    end
  end

  describe "log_spend/4 (ADR-0012's persisted write path)" do
    test "persists consumption against the entries it draws from, so a later read reflects it even after the usage itself ages past the window (the original bug)",
         %{user: user} do
      now = ~U[2026-07-25 10:00:00Z]

      {:ok, activity} =
        PersistenceStub.create_activity(user.id, %{
          name: "Coding",
          time_source_identifier: "coding-proj-1",
          multiplier: 1.0,
          activated_at: ~U[2026-01-01 00:00:00Z]
        })

      raw_entries = %{
        "coding-proj-1" => [
          %{start_date: DateTime.add(now, -1, :day), minutes: 100.0, time_entry_id: "e1"}
        ]
      }

      assert {:ok, %{deficit: deficit}} = PlayBalance.log_spend(user, 100.0, now, [], raw_entries)
      assert deficit == 0.0

      # 8 days later: the entry (now 9 days old) and the spend that drained
      # it are both outside the window. Under the old live-replay design
      # this made backlog_remaining silently reinflate to the full 100.0 —
      # the consumption was "forgotten" once the usage itself aged out.
      later = DateTime.add(now, 8, :day)

      assert {:ok, [row]} = PersistenceStub.list_entry_consumption(user.id)
      assert row.activity_id == activity.id
      assert row.time_entry_id == "e1"
      assert row.consumed_minutes == 100.0

      # A fresh read at `later`, with no raw_entries override, sees nothing
      # new from Timing (the entry is 9 days old, outside any window fetch)
      # — but the persisted consumption is still there regardless.
      assert {:ok, today} = PlayBalance.compute_today(user, later, [], %{})
      assert today.reserve == 0.0
      assert today.playtime == 0.0
    end

    test "draws today's own entries before reserve's, same FIFO order as before", %{user: user} do
      now = ~U[2026-07-25 10:00:00Z]

      {:ok, activity} =
        PersistenceStub.create_activity(user.id, %{
          name: "Coding",
          time_source_identifier: "coding-proj-1",
          multiplier: 1.0,
          activated_at: ~U[2026-01-01 00:00:00Z]
        })

      raw_entries = %{
        "coding-proj-1" => [
          %{start_date: DateTime.add(now, -1, :day), minutes: 50.0, time_entry_id: "yesterday"},
          %{start_date: now, minutes: 20.0, time_entry_id: "today"}
        ]
      }

      assert {:ok, %{receipt: receipt, deficit: deficit}} =
               PlayBalance.log_spend(user, 12.0, now, [], raw_entries)

      assert deficit == 0.0
      assert receipt.breakdown == %{activity.id => 12.0}

      assert {:ok, rows} = PersistenceStub.list_entry_consumption(user.id)
      assert [%{time_entry_id: "today", consumed_minutes: 12.0}] = rows
    end

    test "overflows into reserve once today's own entries are exhausted", %{user: user} do
      now = ~U[2026-07-25 10:00:00Z]

      {:ok, _activity} =
        PersistenceStub.create_activity(user.id, %{
          name: "Coding",
          time_source_identifier: "coding-proj-1",
          multiplier: 1.0,
          activated_at: ~U[2026-01-01 00:00:00Z]
        })

      raw_entries = %{
        "coding-proj-1" => [
          %{start_date: DateTime.add(now, -1, :day), minutes: 50.0, time_entry_id: "yesterday"},
          %{start_date: now, minutes: 5.0, time_entry_id: "today"}
        ]
      }

      assert {:ok, %{deficit: deficit}} = PlayBalance.log_spend(user, 12.0, now, [], raw_entries)
      assert deficit == 0.0

      assert {:ok, rows} = PersistenceStub.list_entry_consumption(user.id)
      assert Enum.find(rows, &(&1.time_entry_id == "today")).consumed_minutes == 5.0
      assert Enum.find(rows, &(&1.time_entry_id == "yesterday")).consumed_minutes == 7.0
    end

    test "registers deficit, rather than reaching into backlog, once today + in-window reserve run dry (ADR-0012's policy change)",
         %{user: user} do
      now = ~U[2026-07-25 10:00:00Z]

      {:ok, _activity} =
        PersistenceStub.create_activity(user.id, %{
          name: "Coding",
          time_source_identifier: "coding-proj-1",
          multiplier: 1.0,
          activated_at: ~U[2026-01-01 00:00:00Z]
        })

      # A huge backlog entry, well outside the window — must never be drawn
      # on, however large the spend.
      raw_entries = %{
        "coding-proj-1" => [
          %{
            start_date: DateTime.add(now, -30, :day),
            minutes: 10_000.0,
            time_entry_id: "ancient"
          },
          %{start_date: DateTime.add(now, -1, :day), minutes: 10.0, time_entry_id: "recent"}
        ]
      }

      assert {:ok, %{deficit: 90.0}} = PlayBalance.log_spend(user, 100.0, now, [], raw_entries)

      assert {:ok, rows} = PersistenceStub.list_entry_consumption(user.id)
      refute Enum.any?(rows, &(&1.time_entry_id == "ancient"))
      assert Enum.find(rows, &(&1.time_entry_id == "recent")).consumed_minutes == 10.0
    end

    test "logs the underlying Playtime Used record", %{user: user} do
      now = ~U[2026-07-25 10:00:00Z]

      assert {:ok, %{usage: usage}} = PlayBalance.log_spend(user, 15.0, now, [], %{})
      assert usage.minutes == 15.0
      assert usage.logged_at == now

      assert {:ok, [logged]} = PersistenceStub.list_playtime_used(user.id)
      assert logged.id == usage.id
    end

    test "normalizes a non-string time_entry_id, so the persisted row is storable and matches on later reads",
         %{user: user} do
      now = ~U[2026-07-25 10:00:00Z]

      {:ok, _activity} =
        PersistenceStub.create_activity(user.id, %{
          name: "Coding",
          time_source_identifier: "coding-proj-1",
          multiplier: 1.0,
          activated_at: ~U[2026-01-01 00:00:00Z]
        })

      # Timing's JSON `id` is not guaranteed to be a string, and an entry
      # with no id at all falls back to its start_date — neither is storable
      # in the ledger's :string column as-is (ADR-0012).
      raw_entries = %{
        "coding-proj-1" => [
          %{start_date: DateTime.add(now, -2, :day), minutes: 10.0, time_entry_id: 12_345},
          %{start_date: DateTime.add(now, -1, :day), minutes: 10.0}
        ]
      }

      assert {:ok, %{deficit: 0.0}} = PlayBalance.log_spend(user, 20.0, now, [], raw_entries)

      assert {:ok, rows} = PersistenceStub.list_entry_consumption(user.id)
      assert Enum.all?(rows, &is_binary(&1.time_entry_id))
      assert Enum.find(rows, &(&1.time_entry_id == "12345")).consumed_minutes == 10.0

      # And the read path keys the same way, so the consumption actually
      # applies rather than the entries reading as still-unspent.
      assert {:ok, today} = PlayBalance.compute_today(user, now, [], raw_entries)
      assert today.reserve == 0.0
    end

    test "refuses the spend when the entries fetch fails, rather than booking it as permanent deficit",
         %{user: user} do
      now = ~U[2026-07-25 10:00:00Z]

      {:ok, _activity} =
        PersistenceStub.create_activity(user.id, %{
          name: "Coding",
          time_source_identifier: "coding-proj-1",
          multiplier: 1.0,
          activated_at: ~U[2026-01-01 00:00:00Z]
        })

      failing_fetch = fn _activities, _opts -> {:error, :timing_unavailable} end

      assert {:error, :timing_unavailable} =
               PlayBalance.log_spend(user, 30.0, now, [], nil, failing_fetch)

      # A Timing outage must not durably record a spend against an empty
      # pool: `deficit` is permanent (total_used - total_consumed), so
      # unlike a failed read it would never self-correct (ADR-0012).
      assert {:ok, []} = PersistenceStub.list_playtime_used(user.id)
      assert {:ok, []} = PersistenceStub.list_entry_consumption(user.id)
    end

    test "returns {:error, :no_timezone} instead of crashing when the User has no timezone yet",
         %{user: user} do
      user = %{user | timezone: nil}
      now = ~U[2026-07-25 10:00:00Z]

      assert {:error, :no_timezone} = PlayBalance.log_spend(user, 15.0, now, [], %{})

      # Nothing is written — the spend never happened, so the User can retry
      # it once their timezone is set (ADR-0005 needs one for the day split).
      assert {:ok, []} = PersistenceStub.list_playtime_used(user.id)
      assert {:ok, []} = PersistenceStub.list_entry_consumption(user.id)
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
      raw_entries = %{
        "coding-proj-1" => [
          %{start_date: ~U[2026-07-25 09:00:00Z], minutes: 30.0, time_entry_id: "e1"}
        ]
      }

      assert {:ok, %{deficit: 50.0}} =
               PlayBalance.log_spend(user, 50.0, ~U[2026-07-25 08:00:00Z], [], raw_entries)

      assert {:ok, today} = PlayBalance.compute_today(user, now, [], raw_entries)

      assert today.earned_today == 30.0
      assert today.used_today == 50.0
      # The 30.0 entry (logged 10:00) is entirely untouched by the 08:00
      # spend, so it survives whole in today_net rather than flooring at 0.
      assert today.today_net == 30.0
      # The 08:00 spend had nothing to draw on at all (no entry existed yet
      # that day, and no reserve) — it's pure deficit, absorbed by reserve.
      assert today.reserve == -45.0

      assert_in_delta today.playtime,
                      today.week_earned - today.week_used + today.pushscroll_balance,
                      0.0001
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

      raw_entries = %{
        "coding-proj-1" => [
          %{start_date: DateTime.add(now, -5, :day), minutes: 20.0, time_entry_id: "coding-old"},
          %{start_date: now, minutes: 15.0, time_entry_id: "coding-today"}
        ],
        "learning-proj-1" => [
          %{start_date: DateTime.add(now, -2, :day), minutes: 40.0, time_entry_id: "learning-old"}
        ]
      }

      assert {:ok, _} =
               PlayBalance.log_spend(user, 10.0, DateTime.add(now, -4, :day), [], raw_entries)

      assert {:ok, _} = PlayBalance.log_spend(user, 55.0, now, [], raw_entries)

      assert {:ok, today} = PlayBalance.compute_today(user, now, [], raw_entries)

      assert_in_delta today.playtime,
                      today.week_earned - today.week_used + today.pushscroll_balance,
                      0.0001
    end
  end

  describe "compute_today/4 with Draining Activities (ADR-0013)" do
    setup %{user: user} do
      {:ok, coding} =
        PersistenceStub.create_activity(user.id, %{
          name: "Coding",
          time_source_identifier: "coding-proj-1",
          multiplier: 1.0,
          activated_at: ~U[2026-01-01 00:00:00Z]
        })

      {:ok, youtube} =
        PersistenceStub.create_activity(user.id, %{
          name: "YouTube",
          time_source_identifier: "youtube-proj-1",
          multiplier: 2.0,
          effect: :negative,
          activated_at: ~U[2026-01-01 00:00:00Z]
        })

      %{coding: coding, youtube: youtube, now: ~U[2026-07-25 10:00:00Z]}
    end

    test "week_drained/drained_today carry the gross drain magnitude; week_earned stays gross",
         %{user: user, now: now} do
      raw_entries = %{
        "coding-proj-1" => [
          %{start_date: ~U[2026-07-25 01:00:00Z], minutes: 40.0, time_entry_id: "c1"}
        ],
        "youtube-proj-1" => [
          %{start_date: ~U[2026-07-25 02:00:00Z], minutes: 10.0, time_entry_id: "y1"}
        ]
      }

      assert {:ok, today} = PlayBalance.compute_today(user, now, [], raw_entries)

      assert today.earned_today == 40.0
      # 10 tracked min * 2.0 multiplier, gross positive magnitude.
      assert today.drained_today == 20.0
      assert today.week_earned == 40.0
      assert today.week_drained == 20.0
      # today_signed = 40 - 20 = 20, above the floor.
      assert today.today_net == 20.0
      assert today.reserve == 0.0
      assert today.playtime == 20.0
    end

    test "a day whose drains exceed its earnings floors today_net at 0 and spills the excess into reserve",
         %{user: user, now: now} do
      raw_entries = %{
        "coding-proj-1" => [
          %{start_date: ~U[2026-07-25 01:00:00Z], minutes: 10.0, time_entry_id: "c1"}
        ],
        "youtube-proj-1" => [
          %{start_date: ~U[2026-07-25 02:00:00Z], minutes: 30.0, time_entry_id: "y1"}
        ]
      }

      assert {:ok, today} = PlayBalance.compute_today(user, now, [], raw_entries)

      # today_signed = 10 - (30 * 2.0) = -50
      assert today.today_net == 0.0
      assert today.reserve == -50.0
      # playtime dropped by the full drain, not floored away.
      assert today.playtime == -50.0
    end

    test "a logged spend never draws from a drain entry — no EntryConsumption row references it",
         %{user: user, now: now, coding: coding, youtube: youtube} do
      raw_entries = %{
        "coding-proj-1" => [
          %{start_date: ~U[2026-07-25 01:00:00Z], minutes: 20.0, time_entry_id: "c1"}
        ],
        "youtube-proj-1" => [
          %{start_date: ~U[2026-07-25 02:00:00Z], minutes: 100.0, time_entry_id: "y1"}
        ]
      }

      # The spend can only reach coding's 20 min; the rest is deficit — the
      # drain's 100 magnitude is not in the pool at all.
      assert {:ok, %{deficit: 30.0}} =
               PlayBalance.log_spend(user, 50.0, now, [], raw_entries)

      assert {:ok, rows} = PersistenceStub.list_entry_consumption(user.id)
      refute Enum.any?(rows, &(&1.activity_id == youtube.id))
      assert [%{activity_id: coding_id, consumed_minutes: 20.0}] = rows
      assert coding_id == coding.id
    end

    test "a drain entry older than the Entry Expiry Window contributes to no window figure",
         %{user: user, now: now} do
      raw_entries = %{
        "youtube-proj-1" => [
          %{start_date: DateTime.add(now, -8, :day), minutes: 100.0, time_entry_id: "y-old"}
        ]
      }

      assert {:ok, today} = PlayBalance.compute_today(user, now, [], raw_entries)

      assert today.week_drained == 0.0
      assert today.drained_today == 0.0
      assert today.playtime == 0.0
    end

    test "playtime == week_earned - week_drained - week_used + pushscroll_balance for a week with drains",
         %{user: user, now: now} do
      {:ok, _} = PersistenceStub.set_manual_sync_total(user.id, 5.0)

      raw_entries = %{
        "coding-proj-1" => [
          %{start_date: DateTime.add(now, -3, :day), minutes: 50.0, time_entry_id: "c-old"},
          %{start_date: ~U[2026-07-25 01:00:00Z], minutes: 20.0, time_entry_id: "c-today"}
        ],
        "youtube-proj-1" => [
          %{start_date: ~U[2026-07-25 02:00:00Z], minutes: 15.0, time_entry_id: "y-today"}
        ]
      }

      assert {:ok, _} = PlayBalance.log_spend(user, 10.0, now, [], raw_entries)

      assert {:ok, today} = PlayBalance.compute_today(user, now, [], raw_entries)

      assert_in_delta today.playtime,
                      today.week_earned - today.week_drained - today.week_used +
                        today.pushscroll_balance,
                      0.0001
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

      # Raw (pre-multiplier) Timing minutes: a reserve entry (5 days back,
      # within the 7-day Entry Expiry Window) and a today entry.
      raw_entries = %{
        "coding-proj-1" => [
          %{start_date: ~U[2026-07-20 09:00:00Z], minutes: 50.0, time_entry_id: "reserve-entry"},
          %{start_date: ~U[2026-07-25 01:00:00Z], minutes: 10.0, time_entry_id: "today-entry"}
        ]
      }

      # Local start of today is 2026-07-24T12:00:00Z.
      assert {:ok, _} =
               PlayBalance.log_spend(user, 30.0, ~U[2026-07-23 09:00:00Z], [], raw_entries)

      assert {:ok, _} =
               PlayBalance.log_spend(user, 15.0, ~U[2026-07-25 05:00:00Z], [], raw_entries)

      now = ~U[2026-07-25 10:00:00Z]

      assert {:ok, today} = PlayBalance.compute_today(user, now, [], raw_entries)

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

    test "zeroes every activity's totals for the computation when raw_entries is an empty map (ADR-0008's shared failure blast radius, now handled by EntryLedger.load/4's own swallow)",
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

      assert {:ok, today} = PlayBalance.compute_today(user, now, [], %{})

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

    test "excludes an entry more than 7 days old from Reserve (Entry Expiry Window)", %{
      user: user
    } do
      now = ~U[2026-07-25 10:00:00Z]

      # Exactly on the boundary: 7 days and 1 minute before `now`, so just
      # outside the window (an exact rolling cutoff, not calendar-aligned).
      raw_entries = %{
        "coding-proj-1" => [
          %{start_date: DateTime.add(now, -7 * 24 * 60 - 1, :minute), minutes: 100.0}
        ]
      }

      {:ok, _} =
        PersistenceStub.create_activity(user.id, %{
          name: "Coding",
          time_source_identifier: "coding-proj-1",
          multiplier: 1.0,
          activated_at: ~U[2026-01-01 00:00:00Z]
        })

      assert {:ok, today} = PlayBalance.compute_today(user, now, [], raw_entries)

      assert today.reserve == 0.0
      assert today.playtime == 0.0
    end

    test "an entry's already-spent minutes are never double-counted against a User once it expires",
         %{user: user} do
      now = ~U[2026-07-25 10:00:00Z]

      # Fully spent (100 earned, 100 used) 8 days ago — outside the window,
      # but its consumption shouldn't leave any residual debt behind either.
      raw_entries = %{
        "coding-proj-1" => [
          %{start_date: DateTime.add(now, -8, :day), minutes: 100.0, time_entry_id: "e1"}
        ]
      }

      {:ok, _} =
        PersistenceStub.create_activity(user.id, %{
          name: "Coding",
          time_source_identifier: "coding-proj-1",
          multiplier: 1.0,
          activated_at: ~U[2026-01-01 00:00:00Z]
        })

      assert {:ok, %{deficit: deficit}} =
               PlayBalance.log_spend(user, 100.0, DateTime.add(now, -8, :day), [], raw_entries)

      assert deficit == 0.0

      assert {:ok, today} = PlayBalance.compute_today(user, now, [], raw_entries)

      assert today.reserve == 0.0
      assert today.playtime == 0.0
    end

    test "an entry that expires after funding a still-recent usage doesn't re-draw from today's fresh entries — and this is the one case where the week_earned/week_used/pushscroll reconciliation genuinely doesn't hold",
         %{user: user} do
      now = ~U[2026-07-25 10:00:00Z]

      # 8 days ago: earned 100, and *at that time* (still within that
      # spend's own 7-day window) a 100-min usage fully drained it. The
      # entry has since aged out of the window (>7 days before `now`), but
      # the usage that drained it hasn't (only 6 days old) — its
      # consumption stays persisted regardless (ADR-0012). Separately,
      # today a fresh 50-min entry is earned, untouched by any spend.
      raw_entries = %{
        "coding-proj-1" => [
          %{start_date: DateTime.add(now, -8, :day), minutes: 100.0, time_entry_id: "old"},
          %{start_date: now, minutes: 50.0, time_entry_id: "today"}
        ]
      }

      {:ok, _} =
        PersistenceStub.create_activity(user.id, %{
          name: "Coding",
          time_source_identifier: "coding-proj-1",
          multiplier: 1.0,
          activated_at: ~U[2026-01-01 00:00:00Z]
        })

      assert {:ok, %{deficit: deficit}} =
               PlayBalance.log_spend(user, 100.0, DateTime.add(now, -6, :day), [], raw_entries)

      assert deficit == 0.0

      assert {:ok, today} = PlayBalance.compute_today(user, now, [], raw_entries)

      # Expected: the 8-day-old entry is gone (expired), but it already
      # absorbed the 6-day-old usage back when both existed — so today's
      # fresh 50 should be fully intact.
      assert today.today_net == 50.0
      assert today.reserve == 0.0
      assert today.playtime == 50.0

      # The 8-day-old entry is outside the window at read time, so none of
      # its 100 counts toward week_earned — but the 6-day-old usage that
      # drained it is still within window, so it counts fully toward
      # week_used. ADR-0010's backlog_drawn used to exist specifically to
      # cover this gap; ADR-0012 removed it (KISS), so the reconciliation
      # identity is *not* exact here — this is the one known, accepted case
      # where it doesn't hold, not a bug.
      assert today.week_earned == 50.0
      assert today.week_used == 100.0
      assert today.week_earned - today.week_used + today.pushscroll_balance == -50.0
      assert today.playtime == 50.0
    end
  end
end
