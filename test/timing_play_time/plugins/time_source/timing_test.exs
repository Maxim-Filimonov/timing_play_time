defmodule TimingPlayTime.Plugins.TimeSource.TimingTest do
  use ExUnit.Case, async: true

  alias ExMCP.Testing.MockServer
  alias TimingPlayTime.Plugins.TimeSource.Timing
  alias TimingPlayTime.Support.TimingMockHandler

  @activity %{
    time_source_identifier: "coding-proj-1",
    activated_at: ~U[2026-07-01 00:00:00Z]
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

    test "defaults :from to the activity's activated_at" do
      MockServer.with_server(
        [handler: TimingMockHandler, state: %{test_pid: self(), entries: []}],
        fn client ->
          assert {:ok, minutes} = Timing.get_elapsed_minutes(@activity, client: client)
          assert minutes == 0.0

          assert_receive {:call_tool, "list_time_entries", arguments}
          assert arguments["start_date_min"] == DateTime.to_iso8601(@activity.activated_at)
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
