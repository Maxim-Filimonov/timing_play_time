defmodule TimingPlayTime.PlayBalanceTodayIntegrationTest do
  @moduledoc """
  Exercises `PlayBalance.today_activity_minutes/4` against the *real*
  `TimingPlayTime.Plugins.TimeSource.Timing` adapter (via ExMCP's test
  transport), not `TimeSource.Stub`.

  Stub ignores `:from`/`:to` filtering entirely (it just multiplies a
  per-project rate by elapsed days), so it can't catch bugs in how the
  "today" date range is built or sent. This queries the real adapter's
  request-building and response-parsing path, against a fake server that
  actually filters by date range like the real Timing server does — the gap
  that let a bug (microsecond-precision timestamps sent to Timing's MCP tool
  in violation of its documented "no microseconds" format) ship silently.
  """

  # async: false — the week_distribution/compute_today reconciliation below
  # exercises TimingPlayTime.Plugins.Persistence.Stub, a globally-named
  # GenServer shared across the process (see play_balance_test.exs).
  use ExUnit.Case, async: false

  alias ExMCP.Testing.MockServer
  alias TimingPlayTime.EntryLedger
  alias TimingPlayTime.PlayBalance
  alias TimingPlayTime.Plugins.Persistence.Stub, as: PersistenceStub
  alias TimingPlayTime.Plugins.TimeSource.Timing
  alias TimingPlayTime.Support.TimingMockHandler

  describe "today_activity_minutes/4 with the real Timing adapter" do
    @user %{timezone: "Pacific/Auckland"}

    test "counts only today's entries, excluding an entry from yesterday" do
      activity = %{
        activated_at: ~U[2026-07-20 00:00:00Z],
        time_source_identifier: "coding-proj-1",
        multiplier: 1.5,
        effect: :positive
      }

      # `now` is 2026-07-26T05:00:00Z = 2026-07-26T17:00:00+12:00 in
      # Pacific/Auckland — local start of today is 2026-07-25T12:00:00Z.
      now = ~U[2026-07-26 05:00:00Z]

      entries = [
        # Yesterday (before local start-of-day) — must be excluded.
        %{
          "duration" => 9999,
          "start_date" => "2026-07-25T10:00:00+00:00",
          "project" => %{"self" => "/projects/coding-proj-1"}
        },
        # Today, within the window — must be counted.
        %{
          "duration" => 3600,
          "start_date" => "2026-07-26T02:00:00+00:00",
          "project" => %{"self" => "/projects/coding-proj-1"}
        }
      ]

      MockServer.with_server(
        [handler: TimingMockHandler, state: %{test_pid: self(), entries: entries}],
        fn client ->
          get_elapsed_minutes = fn a, opts -> Timing.get_elapsed_minutes(a, opts ++ [client: client]) end

          assert {:ok, %{minutes: 60.0, play_minutes: 90.0}} =
                   PlayBalance.today_activity_minutes(activity, @user, now, get_elapsed_minutes)
        end
      )
    end

    test "counts entries from local start-of-day even when activated later that same day" do
      # Activated at 2026-07-25T18:00:00Z: after local start-of-day
      # (2026-07-25T12:00:00Z) but still "today" in local terms
      # (2026-07-26T06:00:00+12:00) — activation partway through today must
      # not clamp `from` forward past local start-of-day, matching the
      # Timing-Derived Earned Total's day-boundary parity (an Activity
      # activated mid-day still earns for time already logged earlier that
      # same day).
      activity = %{
        activated_at: ~U[2026-07-25 18:00:00Z],
        time_source_identifier: "coding-proj-1",
        multiplier: 2.0,
        effect: :positive
      }

      now = ~U[2026-07-26 05:00:00Z]

      entries = [
        # After local start-of-day but before activation — must be counted.
        %{
          "duration" => 9999,
          "start_date" => "2026-07-25T15:00:00+00:00",
          "project" => %{"self" => "/projects/coding-proj-1"}
        },
        # After activation — must be counted.
        %{
          "duration" => 1800,
          "start_date" => "2026-07-26T01:00:00+00:00",
          "project" => %{"self" => "/projects/coding-proj-1"}
        }
      ]

      MockServer.with_server(
        [handler: TimingMockHandler, state: %{test_pid: self(), entries: entries}],
        fn client ->
          get_elapsed_minutes = fn a, opts -> Timing.get_elapsed_minutes(a, opts ++ [client: client]) end

          assert {:ok, %{minutes: 196.65, play_minutes: 393.3}} =
                   PlayBalance.today_activity_minutes(activity, @user, now, get_elapsed_minutes)
        end
      )
    end
  end

  describe "week_distribution/4 reconciles with compute_today/4 (#16)" do
    setup do
      :ok = PersistenceStub.clear_all_state()
      %{user: %{id: Ecto.UUID.generate(), timezone: "Pacific/Auckland"}}
    end

    test "day totals summed over the window equal week_earned / week_drained, from the same fetch",
         %{user: user} do
      # Pacific/Auckland is UTC+12: `now` at 05:00Z is 17:00 local on
      # 2026-07-25, so the 7 chart columns are 2026-07-19..2026-07-25.
      now = ~U[2026-07-25 05:00:00Z]

      {:ok, earner} =
        PersistenceStub.create_activity(user.id, %{
          name: "Coding",
          time_source_identifier: "coding-proj-1",
          multiplier: 1.5,
          effect: :positive,
          activated_at: ~U[2026-01-01 00:00:00Z]
        })

      {:ok, drain} =
        PersistenceStub.create_activity(user.id, %{
          name: "YouTube",
          time_source_identifier: "youtube-proj-1",
          multiplier: 2.0,
          effect: :negative,
          activated_at: ~U[2026-01-01 00:00:00Z]
        })

      entries = [
        entry("coding-proj-1", "c1", "2026-07-20T02:00:00+00:00", 3600),
        entry("coding-proj-1", "c2", "2026-07-23T02:00:00+00:00", 1800),
        entry("youtube-proj-1", "y1", "2026-07-21T02:00:00+00:00", 3600),
        entry("youtube-proj-1", "y2", "2026-07-24T02:00:00+00:00", 900)
      ]

      MockServer.with_server(
        [handler: TimingMockHandler, state: %{test_pid: self(), entries: entries}],
        fn client ->
          list_entries = fn a, opts -> Timing.list_entries(a, opts ++ [client: client]) end
          window_start = PlayBalance.expiry_window_start(now)

          {:ok, raw_entries} =
            EntryLedger.fetch([earner, drain], now, [from: window_start], list_entries)

          {:ok, today} = PlayBalance.compute_today(user, now, [], raw_entries)
          {:ok, dist} = PlayBalance.week_distribution(user, now, [], raw_entries)

          earn_sum = dist.days |> Enum.map(& &1.earn_total) |> Enum.sum()
          drain_sum = dist.days |> Enum.map(& &1.drain_total) |> Enum.sum()

          # (60 + 30) min * 1.5
          assert_in_delta today.week_earned, 135.0, 0.01
          # (60 + 15) min * 2.0
          assert_in_delta today.week_drained, 150.0, 0.01

          assert_in_delta earn_sum, today.week_earned, 0.01
          assert_in_delta drain_sum, today.week_drained, 0.01

          by_date = Map.new(dist.days, &{&1.date, &1})
          assert_in_delta by_date[~D[2026-07-20]].earn_total, 90.0, 0.01
          assert_in_delta by_date[~D[2026-07-23]].earn_total, 45.0, 0.01
          assert_in_delta by_date[~D[2026-07-24]].drain_total, 30.0, 0.01
        end
      )
    end
  end

  defp entry(project, id, start_date, duration) do
    %{
      "id" => id,
      "duration" => duration,
      "start_date" => start_date,
      "project" => %{"self" => "/projects/#{project}"}
    }
  end
end
