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
end
