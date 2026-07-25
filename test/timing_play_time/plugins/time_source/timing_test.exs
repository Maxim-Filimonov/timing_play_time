defmodule TimingPlayTime.Plugins.TimeSource.TimingTest do
  use ExUnit.Case, async: true

  alias ExMCP.Testing.MockServer
  alias TimingPlayTime.Plugins.TimeSource.Timing
  alias TimingPlayTime.Support.TimingMockHandler

  @activity %{
    time_source_identifier: "coding-proj-1",
    activated_at: ~U[2026-07-01 14:32:07Z]
  }

  describe "get_elapsed_minutes/2" do
    test "sums entry durations (seconds) into minutes" do
      entries = [%{"duration" => 1800}, %{"duration" => 900}]

      MockServer.with_server(
        [handler: TimingMockHandler, state: %{test_pid: self(), entries: entries}],
        fn client ->
          assert {:ok, 45.0} = Timing.get_elapsed_minutes(@activity, client: client)
        end
      )
    end

    test "sends the activity's time source identifier and given date range as tool arguments" do
      MockServer.with_server(
        [handler: TimingMockHandler, state: %{test_pid: self(), entries: []}],
        fn client ->
          from = ~U[2026-06-01 00:00:00Z]
          to = ~U[2026-06-15 00:00:00Z]

          assert {:ok, minutes} =
                   Timing.get_elapsed_minutes(@activity, client: client, from: from, to: to)

          assert minutes == 0.0

          assert_receive {:call_tool, "list_time_entries", arguments}
          assert arguments["projects"] == ["coding-proj-1"]
          assert arguments["start_date_min"] == DateTime.to_iso8601(from)
          assert arguments["start_date_max"] == DateTime.to_iso8601(to)
        end
      )
    end

    test "defaults :from to the beginning of the day the activity was activated" do
      MockServer.with_server(
        [handler: TimingMockHandler, state: %{test_pid: self(), entries: []}],
        fn client ->
          assert {:ok, minutes} = Timing.get_elapsed_minutes(@activity, client: client)
          assert minutes == 0.0

          assert_receive {:call_tool, "list_time_entries", arguments}
          assert arguments["start_date_min"] == "2026-07-01T00:00:00Z"
        end
      )
    end

    test "counts an entry started earlier today within a narrow same-day range" do
      # Reproduces the "today" dashboard figure staying 0.0: from/to must be
      # sent without microseconds (Timing's docs: use ISO8601 "without
      # microseconds", e.g. "2019-01-01T00:00:00+00:00") or the real server's
      # date-range filter can silently exclude everything in a narrow window.
      entries = [%{"duration" => 1800, "start_date" => "2026-07-26T02:00:00+00:00"}]

      MockServer.with_server(
        [handler: TimingMockHandler, state: %{test_pid: self(), entries: entries}],
        fn client ->
          # `from`/`to` carry microseconds, exactly as DateTime.utc_now() does
          # in production — the real code must not pass these through as-is.
          from = ~U[2026-07-26 00:00:00.000000Z]
          to = ~U[2026-07-26 10:00:00.123456Z]

          assert {:ok, 30.0} =
                   Timing.get_elapsed_minutes(@activity, client: client, from: from, to: to)

          assert_receive {:call_tool, "list_time_entries", arguments}
          refute arguments["start_date_min"] =~ "."
          refute arguments["start_date_max"] =~ "."
        end
      )
    end

    test "excludes an entry from yesterday when querying a narrow same-day range" do
      entries = [%{"duration" => 1800, "start_date" => "2026-07-25T23:00:00+00:00"}]

      MockServer.with_server(
        [handler: TimingMockHandler, state: %{test_pid: self(), entries: entries}],
        fn client ->
          from = ~U[2026-07-26 00:00:00Z]
          to = ~U[2026-07-26 10:00:00Z]

          assert {:ok, 0.0} =
                   Timing.get_elapsed_minutes(@activity, client: client, from: from, to: to)
        end
      )
    end

    test "returns an error when the tool call reports an error" do
      MockServer.with_server(
        [handler: TimingMockHandler, state: %{test_pid: self(), error: "boom"}],
        fn client ->
          assert {:error, {:tool_error, "boom"}} =
                   Timing.get_elapsed_minutes(@activity, client: client)
        end
      )
    end

    test "returns an error when the tool result isn't parseable JSON" do
      MockServer.with_server(
        [handler: TimingMockHandler, state: %{test_pid: self(), raw_text: "not json"}],
        fn client ->
          assert {:error, {:invalid_tool_result, _}} =
                   Timing.get_elapsed_minutes(@activity, client: client)
        end
      )
    end
  end
end
