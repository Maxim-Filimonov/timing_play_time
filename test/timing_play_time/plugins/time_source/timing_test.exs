defmodule TimingPlayTime.Plugins.TimeSource.TimingTest do
  use ExUnit.Case, async: true

  alias ExMCP.Testing.MockServer
  alias TimingPlayTime.Plugins.TimeSource.Timing
  alias TimingPlayTime.Support.TimingMockHandler

  @coding %{
    time_source_identifier: "coding-proj-1",
    activated_at: ~U[2026-07-01 14:32:07Z]
  }

  @learning %{
    time_source_identifier: "learning-proj-1",
    activated_at: ~U[2026-07-10 03:00:00Z]
  }

  # connect/1 isn't exercised here: it dials the real @mcp_url via
  # ExMCP.Client.start_link, which MockServer.with_server's in-memory
  # transport (used everywhere else in this file) doesn't intercept — there's
  # no way to test it without either a real network call or a refactor to
  # make the transport/URL injectable, neither of which this adapter does
  # today.

  describe "get_elapsed_minutes/2" do
    test "returns {:ok, %{}} without calling the client when given no activities" do
      assert {:ok, %{}} = Timing.get_elapsed_minutes([], client: :unused)
    end

    test "returns :not_connected when no client is given" do
      assert {:error, :not_connected} = Timing.get_elapsed_minutes([@coding], [])
    end

    test "sends every given activity's identifier as the requested projects, in one call" do
      MockServer.with_server(
        [handler: TimingMockHandler, state: %{test_pid: self(), entries: []}],
        fn client ->
          assert {:ok, _totals} =
                   Timing.get_elapsed_minutes([@coding, @learning], client: client)

          assert_receive {:call_tool, "list_time_entries", arguments}
          assert arguments["projects"] == ["coding-proj-1", "learning-proj-1"]
          refute_receive {:call_tool, "list_time_entries", _}
        end
      )
    end

    test "defaults start_date_min to the beginning of the day of the earliest activated-at across all given activities" do
      MockServer.with_server(
        [handler: TimingMockHandler, state: %{test_pid: self(), entries: []}],
        fn client ->
          # @coding (2026-07-01) is earlier than @learning (2026-07-10) — the
          # shared cutoff is the earliest one, not each activity's own
          # (ADR-0008).
          assert {:ok, _totals} =
                   Timing.get_elapsed_minutes([@learning, @coding], client: client)

          assert_receive {:call_tool, "list_time_entries", arguments}
          assert arguments["start_date_min"] == "2026-07-01T00:00:00Z"
        end
      )
    end

    test "sends the given :to (without microseconds) as start_date_max" do
      MockServer.with_server(
        [handler: TimingMockHandler, state: %{test_pid: self(), entries: []}],
        fn client ->
          to = ~U[2026-07-26 10:00:00.123456Z]

          assert {:ok, _totals} = Timing.get_elapsed_minutes([@coding], client: client, to: to)

          assert_receive {:call_tool, "list_time_entries", arguments}
          assert arguments["start_date_max"] == "2026-07-26T10:00:00Z"
          refute arguments["start_date_max"] =~ "."
        end
      )
    end

    test "buckets entries back to each activity by matching the entry's prefixed project self against the bare requested identifier" do
      entries = [
        %{"duration" => 1800, "project" => %{"self" => "/projects/coding-proj-1"}},
        %{"duration" => 600, "project" => %{"self" => "/projects/learning-proj-1"}},
        %{"duration" => 300, "project" => %{"self" => "/projects/learning-proj-1"}}
      ]

      MockServer.with_server(
        [handler: TimingMockHandler, state: %{test_pid: self(), entries: entries}],
        fn client ->
          assert {:ok, totals} =
                   Timing.get_elapsed_minutes([@coding, @learning], client: client)

          assert %{cumulative: 30.0, today: nil} = totals["coding-proj-1"]
          assert %{cumulative: 15.0, today: nil} = totals["learning-proj-1"]
        end
      )
    end

    test "ignores an entry whose project doesn't match any given activity" do
      entries = [
        %{"duration" => 1800, "project" => %{"self" => "/projects/coding-proj-1"}},
        %{"duration" => 9999, "project" => %{"self" => "/projects/some-other-project"}}
      ]

      MockServer.with_server(
        [handler: TimingMockHandler, state: %{test_pid: self(), entries: entries}],
        fn client ->
          assert {:ok, totals} = Timing.get_elapsed_minutes([@coding], client: client)
          assert %{cumulative: 30.0} = totals["coding-proj-1"]
        end
      )
    end

    test "returns a zeroed bucket for an activity with no matching entries" do
      MockServer.with_server(
        [handler: TimingMockHandler, state: %{test_pid: self(), entries: []}],
        fn client ->
          assert {:ok, totals} = Timing.get_elapsed_minutes([@coding], client: client)
          assert %{cumulative: cumulative, today: nil} = totals["coding-proj-1"]
          assert cumulative == 0.0
        end
      )
    end

    test "splits an activity's matched entries into cumulative (all) and today (at or after :today_from)" do
      entries = [
        %{
          "duration" => 1800,
          "project" => %{"self" => "/projects/coding-proj-1"},
          "start_date" => "2026-07-25T10:00:00+00:00"
        },
        %{
          "duration" => 600,
          "project" => %{"self" => "/projects/coding-proj-1"},
          "start_date" => "2026-07-26T02:00:00+00:00"
        }
      ]

      MockServer.with_server(
        [handler: TimingMockHandler, state: %{test_pid: self(), entries: entries}],
        fn client ->
          today_from = ~U[2026-07-26 00:00:00Z]

          assert {:ok, totals} =
                   Timing.get_elapsed_minutes([@coding],
                     client: client,
                     to: ~U[2026-07-26 10:00:00Z],
                     today_from: today_from
                   )

          # cumulative counts both entries; today only the one at/after the cutoff.
          assert %{cumulative: 40.0, today: 10.0} = totals["coding-proj-1"]
        end
      )
    end

    test "returns today: nil for every activity when :today_from isn't given" do
      entries = [%{"duration" => 1800, "project" => %{"self" => "/projects/coding-proj-1"}}]

      MockServer.with_server(
        [handler: TimingMockHandler, state: %{test_pid: self(), entries: entries}],
        fn client ->
          assert {:ok, totals} = Timing.get_elapsed_minutes([@coding], client: client)
          assert %{today: nil} = totals["coding-proj-1"]
        end
      )
    end

    test "paginates backward when a page returns the maximum of 1000 entries" do
      base = ~U[2026-07-26 12:00:00Z]

      # 1200 one-minute entries, one second apart, newest first — page one
      # (capped at 1000 by the mock, mirroring the real server) covers the
      # newest 1000; the adapter must re-query for the remaining 200 older
      # ones instead of silently dropping them.
      entries =
        for i <- 0..1199 do
          %{
            "duration" => 60,
            "project" => %{"self" => "/projects/coding-proj-1"},
            "start_date" => base |> DateTime.add(-i, :second) |> DateTime.to_iso8601()
          }
        end

      activity = %{@coding | activated_at: DateTime.add(base, -2, :day)}

      MockServer.with_server(
        [handler: TimingMockHandler, state: %{test_pid: self(), entries: entries}],
        fn client ->
          assert {:ok, totals} =
                   Timing.get_elapsed_minutes([activity], client: client, to: base)

          assert_receive {:call_tool, "list_time_entries", first_args}
          assert_receive {:call_tool, "list_time_entries", second_args}
          refute_receive {:call_tool, "list_time_entries", _}

          assert first_args["start_date_max"] == DateTime.to_iso8601(DateTime.truncate(base, :second))
          assert second_args["start_date_max"] != first_args["start_date_max"]

          # All 1200 minutes recovered across both pages, none dropped or
          # double-counted at the pagination boundary.
          assert %{cumulative: 1200.0} = totals["coding-proj-1"]
        end
      )
    end

    test "returns an error when the tool call reports an error" do
      MockServer.with_server(
        [handler: TimingMockHandler, state: %{test_pid: self(), error: "boom"}],
        fn client ->
          assert {:error, {:tool_error, "boom"}} =
                   Timing.get_elapsed_minutes([@coding], client: client)
        end
      )
    end

    test "returns an error when the tool result isn't parseable JSON" do
      MockServer.with_server(
        [handler: TimingMockHandler, state: %{test_pid: self(), raw_text: "not json"}],
        fn client ->
          assert {:error, {:invalid_tool_result, _}} =
                   Timing.get_elapsed_minutes([@coding], client: client)
        end
      )
    end
  end

  describe "list_entries/2" do
    test "returns {:ok, %{}} without calling the client when given no activities" do
      assert {:ok, %{}} = Timing.list_entries([], client: :unused)
    end

    test "returns :not_connected when no client is given" do
      assert {:error, :not_connected} = Timing.list_entries([@coding], [])
    end

    test "defaults start_date_min to the beginning of time (no Activated-At floor) when :from is omitted" do
      MockServer.with_server(
        [handler: TimingMockHandler, state: %{test_pid: self(), entries: []}],
        fn client ->
          assert {:ok, _entries} = Timing.list_entries([@coding], client: client)

          assert_receive {:call_tool, "list_time_entries", arguments}
          assert arguments["start_date_min"] == "1970-01-01T00:00:00Z"
        end
      )
    end

    test "sends the given :from (without microseconds) as start_date_min, unlike get_elapsed_minutes/2's Activated-At floor (ADR-0010)" do
      MockServer.with_server(
        [handler: TimingMockHandler, state: %{test_pid: self(), entries: []}],
        fn client ->
          from = ~U[2026-07-18 10:00:00.123456Z]

          assert {:ok, _entries} = Timing.list_entries([@coding], client: client, from: from)

          assert_receive {:call_tool, "list_time_entries", arguments}
          assert arguments["start_date_min"] == "2026-07-18T10:00:00Z"
        end
      )
    end

    test "sends the given :to (without microseconds) as start_date_max" do
      MockServer.with_server(
        [handler: TimingMockHandler, state: %{test_pid: self(), entries: []}],
        fn client ->
          to = ~U[2026-07-26 10:00:00.123456Z]

          assert {:ok, _entries} = Timing.list_entries([@coding], client: client, to: to)

          assert_receive {:call_tool, "list_time_entries", arguments}
          assert arguments["start_date_max"] == "2026-07-26T10:00:00Z"
        end
      )
    end

    test "returns each matched entry's start_date and minutes (not seconds), bucketed per activity" do
      entries = [
        %{
          "duration" => 1800,
          "project" => %{"self" => "/projects/coding-proj-1"},
          "start_date" => "2026-07-20T09:00:00+00:00"
        },
        %{
          "duration" => 600,
          "project" => %{"self" => "/projects/learning-proj-1"},
          "start_date" => "2026-07-21T09:00:00+00:00"
        }
      ]

      MockServer.with_server(
        [handler: TimingMockHandler, state: %{test_pid: self(), entries: entries}],
        fn client ->
          assert {:ok, by_identifier} = Timing.list_entries([@coding, @learning], client: client)

          assert by_identifier["coding-proj-1"] == [
                   %{start_date: ~U[2026-07-20 09:00:00Z], minutes: 30.0}
                 ]

          assert by_identifier["learning-proj-1"] == [
                   %{start_date: ~U[2026-07-21 09:00:00Z], minutes: 10.0}
                 ]
        end
      )
    end

    test "ignores an entry whose project doesn't match any given activity" do
      entries = [
        %{
          "duration" => 1800,
          "project" => %{"self" => "/projects/coding-proj-1"},
          "start_date" => "2026-07-20T09:00:00+00:00"
        },
        %{
          "duration" => 9999,
          "project" => %{"self" => "/projects/some-other-project"},
          "start_date" => "2026-07-20T09:00:00+00:00"
        }
      ]

      MockServer.with_server(
        [handler: TimingMockHandler, state: %{test_pid: self(), entries: entries}],
        fn client ->
          assert {:ok, by_identifier} = Timing.list_entries([@coding], client: client)
          assert [%{minutes: 30.0}] = by_identifier["coding-proj-1"]
        end
      )
    end

    test "returns an empty list (not absent) for an activity with no matching entries" do
      MockServer.with_server(
        [handler: TimingMockHandler, state: %{test_pid: self(), entries: []}],
        fn client ->
          assert {:ok, by_identifier} = Timing.list_entries([@coding], client: client)
          assert by_identifier["coding-proj-1"] == []
        end
      )
    end

    test "returns an error when the tool call reports an error" do
      MockServer.with_server(
        [handler: TimingMockHandler, state: %{test_pid: self(), error: "boom"}],
        fn client ->
          assert {:error, {:tool_error, "boom"}} = Timing.list_entries([@coding], client: client)
        end
      )
    end
  end
end
