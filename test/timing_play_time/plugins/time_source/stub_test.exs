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

    test "gives each generated entry a stable, unique :time_entry_id (ADR-0012's consumption key)" do
      to = ~U[2026-07-02 00:00:00Z]

      assert {:ok, entries} = Stub.list_entries([@coding], to: to)
      ids = Enum.map(entries["coding-proj-1"], & &1.time_entry_id)

      assert Enum.all?(ids, &is_binary/1)
      assert Enum.uniq(ids) == ids

      assert {:ok, entries_again} = Stub.list_entries([@coding], to: to)
      assert Enum.map(entries_again["coding-proj-1"], & &1.time_entry_id) == ids
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

  describe "list_sources/1" do
    test "returns the fixed 2-level hierarchy, flat and in pre-order DFS (alpha within a level)" do
      assert {:ok, sources} = Stub.list_sources([])

      assert sources == [
               %{id: "dev", title: "Development", ancestors: [], depth: 0},
               %{id: "coding-app", title: "App", ancestors: ["Development"], depth: 1},
               %{id: "writing-docs", title: "Docs", ancestors: ["Development"], depth: 1},
               %{id: "move", title: "Exercise", ancestors: [], depth: 0},
               %{id: "exercise-walk", title: "Walking", ancestors: ["Exercise"], depth: 1},
               %{id: "learn", title: "Learning", ancestors: [], depth: 0},
               %{id: "learning-elixir", title: "Elixir", ancestors: ["Learning"], depth: 1}
             ]
    end

    test "every leaf id keeps a prefix daily_rate/1 matches, so it still earns a rate" do
      {:ok, sources} = Stub.list_sources([])
      to = ~U[2026-07-02 00:00:00Z]
      from = ~U[2026-07-01 00:00:00Z]

      leaf_rates =
        for %{id: id, depth: 1} <- sources, into: %{} do
          activity = %{time_source_identifier: id, activated_at: from}
          {:ok, totals} = Stub.get_elapsed_minutes([activity], to: to, today_from: from)
          {id, totals[id].cumulative}
        end

      assert leaf_rates == %{
               "coding-app" => 45.0,
               "writing-docs" => 30.0,
               "exercise-walk" => 36.0,
               "learning-elixir" => 42.0
             }
    end

    test "ignores opts and never errors" do
      assert {:ok, _} = Stub.list_sources([])
      assert {:ok, sources} = Stub.list_sources(client: :anything)
      assert length(sources) == 7
    end
  end
end
