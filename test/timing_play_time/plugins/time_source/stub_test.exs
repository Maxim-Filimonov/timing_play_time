defmodule TimingPlayTime.Plugins.TimeSource.StubTest do
  use ExUnit.Case, async: true

  alias TimingPlayTime.Plugins.TimeSource.Stub

  @coding %{time_source_identifier: "coding-proj-1", activated_at: ~U[2026-07-01 00:00:00Z]}

  describe "list_entries/2" do
    test "generates one entry per elapsed day since activated_at when :from is omitted" do
      to = ~U[2026-07-04 00:00:00Z]

      assert {:ok, entries} = Stub.list_entries([@coding], to: to)

      assert Enum.map(entries["coding-proj-1"], & &1.start_date) == [
               ~U[2026-07-01 00:00:00Z],
               ~U[2026-07-02 00:00:00Z],
               ~U[2026-07-03 00:00:00Z],
               ~U[2026-07-04 00:00:00Z]
             ]
    end

    test "clips generated entries to :from when it's later than activated_at (ADR-0010's windowed fetch)" do
      to = ~U[2026-07-04 00:00:00Z]
      from = ~U[2026-07-03 00:00:00Z]

      assert {:ok, entries} = Stub.list_entries([@coding], from: from, to: to)

      assert Enum.map(entries["coding-proj-1"], & &1.start_date) == [
               ~U[2026-07-03 00:00:00Z],
               ~U[2026-07-04 00:00:00Z]
             ]
    end

    test "ignores :from when it's earlier than activated_at (activated_at still the effective floor)" do
      to = ~U[2026-07-04 00:00:00Z]
      from = ~U[2026-06-01 00:00:00Z]

      assert {:ok, entries} = Stub.list_entries([@coding], from: from, to: to)

      assert List.first(entries["coding-proj-1"]).start_date == ~U[2026-07-01 00:00:00Z]
    end

    test "every generated entry is worth the project's daily rate" do
      to = ~U[2026-07-02 00:00:00Z]

      assert {:ok, entries} = Stub.list_entries([@coding], to: to)

      assert Enum.map(entries["coding-proj-1"], & &1.minutes) == [45.0, 45.0]
    end

    test "returns an empty list for an activity with no activated_at, given an explicit :from" do
      activity = %{time_source_identifier: "coding-proj-2", activated_at: nil}
      from = ~U[2026-07-03 00:00:00Z]
      to = ~U[2026-07-04 00:00:00Z]

      assert {:ok, entries} = Stub.list_entries([activity], from: from, to: to)

      assert Enum.map(entries["coding-proj-2"], & &1.start_date) == [
               ~U[2026-07-03 00:00:00Z],
               ~U[2026-07-04 00:00:00Z]
             ]
    end
  end
end
