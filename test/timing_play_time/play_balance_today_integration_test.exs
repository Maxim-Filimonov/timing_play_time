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

  use ExUnit.Case, async: true

  alias ExMCP.Testing.MockServer
  alias TimingPlayTime.PlayBalance
  alias TimingPlayTime.Plugins.TimeSource.Timing
  alias TimingPlayTime.Support.TimingMockHandler

  describe "today_activity_minutes/4 with the real Timing adapter" do
    @user %{timezone: "Pacific/Auckland"}

    test "counts only today's entries, excluding an entry from yesterday" do
      activity = %{
        activated_at: ~U[2026-07-20 00:00:00Z],
        time_source_identifier: "coding-proj-1",
        multiplier: 1.5
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
        multiplier: 2.0
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
end
