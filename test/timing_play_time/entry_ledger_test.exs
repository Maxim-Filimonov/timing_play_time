defmodule TimingPlayTime.EntryLedgerTest do
  use ExUnit.Case, async: true

  alias TimingPlayTime.EntryLedger

  # Pacific/Auckland, NZST (UTC+12, no DST in July) — local start of
  # 2026-07-25 is 2026-07-24T12:00:00Z.
  @tz "Pacific/Auckland"

  describe "replay/3 with no usages" do
    test "leaves every entry's remaining equal to its play_minutes" do
      entries = [
        %{activity_id: "coding", start_date: ~U[2026-07-20 01:00:00Z], play_minutes: 30.0},
        %{activity_id: "learning", start_date: ~U[2026-07-22 01:00:00Z], play_minutes: 10.0}
      ]

      assert %{entries: replayed, receipts: [], deficit: deficit} = EntryLedger.replay(entries, [], @tz)
      assert deficit == 0.0

      assert Enum.map(replayed, &{&1.activity_id, &1.remaining}) == [
               {"coding", 30.0},
               {"learning", 10.0}
             ]
    end
  end

  describe "replay/3 consuming today's own entries first" do
    test "draws only from entries dated the usage's own local day, leaving older entries untouched" do
      entries = [
        # Yesterday, relative to the usage below.
        %{activity_id: "coding", start_date: ~U[2026-07-24 01:00:00Z], play_minutes: 50.0},
        # Today, relative to the usage below (local start of today is 2026-07-24T12:00:00Z).
        %{activity_id: "coding", start_date: ~U[2026-07-25 01:00:00Z], play_minutes: 20.0}
      ]

      usages = [%{id: "u1", minutes: 12.0, logged_at: ~U[2026-07-25 05:00:00Z]}]

      assert %{entries: replayed, receipts: receipts, deficit: deficit} =
               EntryLedger.replay(entries, usages, @tz)

      assert deficit == 0.0

      assert [%{start_date: ~U[2026-07-24 01:00:00Z], remaining: 50.0}, %{start_date: ~U[2026-07-25 01:00:00Z], remaining: 8.0}] =
               replayed

      assert [%{usage_id: "u1", breakdown: %{"coding" => 12.0}}] = receipts
    end

    test "overflows into reserve entries, oldest start_date first, once today's own entries are exhausted" do
      entries = [
        %{activity_id: "coding", start_date: ~U[2026-07-10 01:00:00Z], play_minutes: 5.0},
        %{activity_id: "coding", start_date: ~U[2026-07-15 01:00:00Z], play_minutes: 5.0},
        %{activity_id: "coding", start_date: ~U[2026-07-25 01:00:00Z], play_minutes: 8.0}
      ]

      usages = [%{id: "u1", minutes: 15.0, logged_at: ~U[2026-07-25 05:00:00Z]}]

      assert %{entries: replayed, receipts: receipts, deficit: deficit} =
               EntryLedger.replay(entries, usages, @tz)

      assert deficit == 0.0

      # Today's entry (8.0) fully drained first, then the two reserve entries
      # oldest-first: 07-10 (5.0) fully drained, then 07-15 takes the last 2.0.
      assert [
               %{start_date: ~U[2026-07-10 01:00:00Z], remaining: remaining_10},
               %{start_date: ~U[2026-07-15 01:00:00Z], remaining: 3.0},
               %{start_date: ~U[2026-07-25 01:00:00Z], remaining: remaining_25}
             ] = replayed

      assert remaining_10 == 0.0
      assert remaining_25 == 0.0

      assert [%{usage_id: "u1", breakdown: %{"coding" => 15.0}}] = receipts
    end

    test "attributes overflow consumption per-Activity in the Spend Receipt" do
      entries = [
        %{activity_id: "learning", start_date: ~U[2026-07-10 01:00:00Z], play_minutes: 5.0},
        %{activity_id: "coding", start_date: ~U[2026-07-25 01:00:00Z], play_minutes: 8.0}
      ]

      usages = [%{id: "u1", minutes: 10.0, logged_at: ~U[2026-07-25 05:00:00Z]}]

      assert %{receipts: [%{usage_id: "u1", breakdown: breakdown}]} =
               EntryLedger.replay(entries, usages, @tz)

      assert breakdown == %{"coding" => 8.0, "learning" => 2.0}
    end
  end

  describe "replay/3 causality" do
    test "a usage cannot draw on an entry that didn't exist yet" do
      entries = [
        # Earned the day after the usage below — must be untouched by it.
        %{activity_id: "coding", start_date: ~U[2026-07-26 01:00:00Z], play_minutes: 20.0}
      ]

      usages = [%{id: "u1", minutes: 10.0, logged_at: ~U[2026-07-25 05:00:00Z]}]

      assert %{entries: [%{remaining: 20.0}], deficit: 10.0} = EntryLedger.replay(entries, usages, @tz)
    end

    test "replays usages in chronological order regardless of input order" do
      entries = [
        %{activity_id: "coding", start_date: ~U[2026-07-24 01:00:00Z], play_minutes: 10.0}
      ]

      # Given out of order: the earlier usage (u1) must still be processed
      # first, draining the entry before u2 (logged later, same day) sees it.
      usages = [
        %{id: "u2", minutes: 4.0, logged_at: ~U[2026-07-24 08:00:00Z]},
        %{id: "u1", minutes: 7.0, logged_at: ~U[2026-07-24 03:00:00Z]}
      ]

      assert %{entries: [%{remaining: remaining}], receipts: receipts, deficit: 1.0} =
               EntryLedger.replay(entries, usages, @tz)

      assert remaining == 0.0

      # Receipts come back in the given (unsorted) usages order.
      assert [
               %{usage_id: "u2", breakdown: %{"coding" => 3.0}},
               %{usage_id: "u1", breakdown: %{"coding" => 7.0}}
             ] = receipts
    end
  end

  describe "load/4" do
    test "fetches with no :from present, regardless of how many times it's called" do
      test_pid = self()
      activities = [%{time_source_identifier: "coding-proj-1"}]
      now = ~U[2026-07-25 10:00:00Z]

      list_entries = fn _activities, opts ->
        send(test_pid, {:list_entries_opts, opts})
        {:ok, %{}}
      end

      EntryLedger.load(activities, now, [], list_entries)

      assert_received {:list_entries_opts, opts}
      refute Keyword.has_key?(opts, :from)
      assert Keyword.get(opts, :to) == now
    end

    test "swallows a fetch error to an empty map rather than propagating it" do
      activities = [%{time_source_identifier: "coding-proj-1"}]
      list_entries = fn _activities, _opts -> {:error, :boom} end

      assert EntryLedger.load(activities, ~U[2026-07-25 10:00:00Z], [], list_entries) == %{}
    end
  end

  describe "build_entries/2" do
    test "applies each Activity's multiplier and tags entries with the Activity" do
      activities = [
        %{id: "a1", time_source_identifier: "coding-proj-1", multiplier: 2.0, effect: :positive}
      ]

      raw_entries = %{
        "coding-proj-1" => [
          %{start_date: ~U[2026-07-25 01:00:00Z], minutes: 10.0, time_entry_id: "e1"}
        ]
      }

      assert [entry] = EntryLedger.build_entries(activities, raw_entries)
      assert entry.activity_id == "a1"
      assert entry.time_entry_id == "e1"
      assert entry.play_minutes == 20.0
      assert entry.effect == :positive
      assert entry.start_date == ~U[2026-07-25 01:00:00Z]
    end

    test "copies each Activity's effect onto its entries, leaving play_minutes an unsigned magnitude (ADR-0013)" do
      activities = [
        %{id: "drain", time_source_identifier: "youtube-proj-1", multiplier: 2.0, effect: :negative}
      ]

      raw_entries = %{
        "youtube-proj-1" => [
          %{start_date: ~U[2026-07-25 01:00:00Z], minutes: 10.0, time_entry_id: "e1"}
        ]
      }

      assert [entry] = EntryLedger.build_entries(activities, raw_entries)
      assert entry.effect == :negative
      # Magnitude only — no sign applied here.
      assert entry.play_minutes == 20.0
    end

    test "normalizes every time_entry_id to a string, including the start_date fallback" do
      activities = [%{id: "a1", time_source_identifier: "coding-proj-1", multiplier: 1.0, effect: :positive}]

      raw_entries = %{
        "coding-proj-1" => [
          %{start_date: ~U[2026-07-25 01:00:00Z], minutes: 10.0, time_entry_id: 12_345},
          %{start_date: ~U[2026-07-26 01:00:00Z], minutes: 10.0}
        ]
      }

      assert [with_id, without_id] = EntryLedger.build_entries(activities, raw_entries)
      assert with_id.time_entry_id == "12345"
      assert is_binary(without_id.time_entry_id)
    end

    test "skips an Activity with no entries in the fetch" do
      activities = [%{id: "a1", time_source_identifier: "coding-proj-1", multiplier: 1.0, effect: :positive}]

      assert EntryLedger.build_entries(activities, %{}) == []
    end
  end

  describe "fetch/4" do
    test "returns the entries tagged, on success" do
      activities = [%{time_source_identifier: "coding-proj-1"}]
      entries = %{"coding-proj-1" => []}
      list_entries = fn _activities, _opts -> {:ok, entries} end

      assert {:ok, ^entries} =
               EntryLedger.fetch(activities, ~U[2026-07-25 10:00:00Z], [], list_entries)
    end

    test "propagates a fetch error rather than swallowing it to an empty map" do
      activities = [%{time_source_identifier: "coding-proj-1"}]
      list_entries = fn _activities, _opts -> {:error, :boom} end

      assert {:error, :boom} =
               EntryLedger.fetch(activities, ~U[2026-07-25 10:00:00Z], [], list_entries)
    end

    test "passes the caller's opts through, alongside :to" do
      test_pid = self()
      activities = [%{time_source_identifier: "coding-proj-1"}]
      now = ~U[2026-07-25 10:00:00Z]
      window_start = ~U[2026-07-18 10:00:00Z]

      list_entries = fn _activities, opts ->
        send(test_pid, {:list_entries_opts, opts})
        {:ok, %{}}
      end

      EntryLedger.fetch(activities, now, [from: window_start], list_entries)

      assert_received {:list_entries_opts, opts}
      assert Keyword.get(opts, :to) == now
      assert Keyword.get(opts, :from) == window_start
    end
  end

  describe "replay/3 deficit" do
    test "is zero when every usage is fully covered" do
      entries = [%{activity_id: "coding", start_date: ~U[2026-07-25 01:00:00Z], play_minutes: 20.0}]
      usages = [%{id: "u1", minutes: 20.0, logged_at: ~U[2026-07-25 05:00:00Z]}]

      assert %{deficit: deficit} = EntryLedger.replay(entries, usages, @tz)
      assert deficit == 0.0
    end

    test "accumulates the unmatched portion across multiple under-funded usages" do
      usages = [
        %{id: "u1", minutes: 30.0, logged_at: ~U[2026-07-25 05:00:00Z]},
        %{id: "u2", minutes: 15.0, logged_at: ~U[2026-07-26 05:00:00Z]}
      ]

      assert %{deficit: 45.0, receipts: receipts} = EntryLedger.replay([], usages, @tz)
      assert [%{breakdown: %{}}, %{breakdown: %{}}] = receipts
    end
  end

  describe "replay/3 with a pre-loaded :remaining (ADR-0012's persisted ledger)" do
    test "consumes from the given :remaining rather than resetting it to play_minutes" do
      # An entry already partially drawn on by a previous, already-persisted
      # spend: 20 earned, only 5 left.
      entries = [
        %{
          activity_id: "coding",
          start_date: ~U[2026-07-25 01:00:00Z],
          play_minutes: 20.0,
          remaining: 5.0
        }
      ]

      usages = [%{id: "u1", minutes: 5.0, logged_at: ~U[2026-07-25 05:00:00Z]}]

      assert %{entries: [replayed], deficit: deficit} = EntryLedger.replay(entries, usages, @tz)

      assert deficit == 0.0
      assert replayed.remaining == 0.0
      # The original earned total is untouched — only :remaining moved.
      assert replayed.play_minutes == 20.0
    end

    test "defaults :remaining to play_minutes when the entry doesn't already carry one" do
      entries = [%{activity_id: "coding", start_date: ~U[2026-07-25 01:00:00Z], play_minutes: 20.0}]

      assert %{entries: [replayed]} = EntryLedger.replay(entries, [], @tz)

      assert replayed.remaining == 20.0
    end
  end

  describe "index_consumption/1" do
    test "keys consumed minutes by {activity_id, time_entry_id}" do
      rows = [
        %{activity_id: "coding", time_entry_id: "t1", consumed_minutes: 12.0},
        %{activity_id: "coding", time_entry_id: "t2", consumed_minutes: 4.0}
      ]

      assert EntryLedger.index_consumption(rows) == %{
               {"coding", "t1"} => 12.0,
               {"coding", "t2"} => 4.0
             }
    end

    test "is an empty map for no rows" do
      assert EntryLedger.index_consumption([]) == %{}
    end
  end

  describe "with_remaining/2" do
    test "sets remaining to play_minutes minus indexed consumption for that entry" do
      entries = [
        %{activity_id: "coding", time_entry_id: "t1", start_date: ~U[2026-07-25 01:00:00Z], play_minutes: 20.0}
      ]

      index = EntryLedger.index_consumption([%{activity_id: "coding", time_entry_id: "t1", consumed_minutes: 12.0}])

      assert [%{remaining: 8.0}] = EntryLedger.with_remaining(entries, index)
    end

    test "defaults remaining to the full play_minutes when the entry has no consumption row" do
      entries = [
        %{activity_id: "coding", time_entry_id: "t1", start_date: ~U[2026-07-25 01:00:00Z], play_minutes: 20.0}
      ]

      assert [%{remaining: 20.0}] = EntryLedger.with_remaining(entries, %{})
    end

    test "floors remaining at zero rather than going negative" do
      entries = [
        %{activity_id: "coding", time_entry_id: "t1", start_date: ~U[2026-07-25 01:00:00Z], play_minutes: 20.0}
      ]

      index = EntryLedger.index_consumption([%{activity_id: "coding", time_entry_id: "t1", consumed_minutes: 25.0}])

      assert [%{remaining: remaining}] = EntryLedger.with_remaining(entries, index)
      assert remaining == 0.0
    end
  end

  describe "total_consumed/1" do
    test "sums consumed minutes across every row, regardless of activity or entry" do
      rows = [
        %{activity_id: "coding", time_entry_id: "t1", consumed_minutes: 12.0},
        %{activity_id: "learning", time_entry_id: "t2", consumed_minutes: 4.5}
      ]

      assert EntryLedger.total_consumed(rows) == 16.5
    end

    test "is zero for no rows" do
      assert EntryLedger.total_consumed([]) == 0.0
    end
  end
end
