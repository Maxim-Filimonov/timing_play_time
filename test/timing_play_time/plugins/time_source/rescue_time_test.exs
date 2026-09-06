defmodule TimingPlayTime.Plugins.TimeSource.RescueTimeTest do
  use ExUnit.Case, async: true

  alias TimingPlayTime.Plugins.TimeSource.RescueTime

  @coding %{
    time_source_identifier: "Code Editors",
    activated_at: ~U[2026-07-01 00:00:00Z]
  }

  @browsing %{
    time_source_identifier: "Web Browsers",
    activated_at: ~U[2026-07-10 00:00:00Z]
  }

  setup do
    Application.put_env(:timing_play_time, :rescuetime_req_plug, {Req.Test, __MODULE__})
    on_exit(fn -> Application.delete_env(:timing_play_time, :rescuetime_req_plug) end)
    :ok
  end

  defp stub_rows(rows) do
    Req.Test.stub(__MODULE__, fn conn ->
      Req.Test.json(conn, %{"rows" => rows})
    end)
  end

  describe "connect/1" do
    test "accepts %{\"api_key\" => binary} without making an HTTP call" do
      Req.Test.stub(__MODULE__, fn _conn ->
        flunk("connect/1 must not make an HTTP call")
      end)

      assert {:ok, "my-key"} = RescueTime.connect(%{"api_key" => "my-key"})
    end

    test "rejects anything else" do
      assert {:error, :invalid_credentials} = RescueTime.connect(%{})
      assert {:error, :invalid_credentials} = RescueTime.connect(%{"api_key" => 123})
      assert {:error, :invalid_credentials} = RescueTime.connect("not a map")
    end
  end

  describe "get_elapsed_minutes/2" do
    test "returns {:ok, %{}} without calling the API when given no activities" do
      Req.Test.stub(__MODULE__, fn _conn -> flunk("should not be called") end)

      assert {:ok, %{}} = RescueTime.get_elapsed_minutes([], client: "key")
    end

    test "returns :not_connected when no client is given" do
      assert {:error, :not_connected} = RescueTime.get_elapsed_minutes([@coding], [])
    end

    test "batches every given activity into one call, never sending restrict_thing" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        send(test_pid, {:query, conn.query_params})
        Req.Test.json(conn, %{"rows" => []})
      end)

      assert {:ok, _totals} =
               RescueTime.get_elapsed_minutes([@coding, @browsing], client: "key")

      assert_receive {:query, query}
      refute Map.has_key?(query, "restrict_thing")
      assert query["restrict_kind"] == "activity"
      assert query["perspective"] == "interval"
    end

    test "sums matched rows' seconds into minutes, per requested activity, ignoring unmatched rows" do
      rows = [
        ["2026-07-15 09:00:00", 600, 1, "Code Editors", "Software Development", 2],
        ["2026-07-15 10:00:00", 300, 1, "Code Editors", "Software Development", 2],
        ["2026-07-15 09:00:00", 900, 1, "Some Other App", "Utilities", 0]
      ]

      stub_rows(rows)

      assert {:ok, totals} = RescueTime.get_elapsed_minutes([@coding, @browsing], client: "key")

      assert totals["Code Editors"].cumulative == 15.0
      assert totals["Web Browsers"].cumulative == 0.0
      refute Map.has_key?(totals, "Some Other App")
    end

    test "splits cumulative vs today via :today_from" do
      rows = [
        ["2026-07-14 09:00:00", 600, 1, "Code Editors", "Software Development", 2],
        ["2026-07-15 09:00:00", 300, 1, "Code Editors", "Software Development", 2]
      ]

      stub_rows(rows)

      assert {:ok, totals} =
               RescueTime.get_elapsed_minutes([@coding],
                 client: "key",
                 to: ~U[2026-07-15 23:59:59Z],
                 today_from: ~U[2026-07-15 00:00:00Z]
               )

      assert totals["Code Editors"].cumulative == 15.0
      assert totals["Code Editors"].today == 5.0
    end
  end

  describe "list_entries/2" do
    test "returns {:ok, %{}} without calling the API when given no activities" do
      Req.Test.stub(__MODULE__, fn _conn -> flunk("should not be called") end)

      assert {:ok, %{}} = RescueTime.list_entries([], client: "key")
    end

    test "returns :not_connected when no client is given" do
      assert {:error, :not_connected} = RescueTime.list_entries([@coding], [])
    end

    test "every requested activity gets an entry, even with zero matching rows" do
      stub_rows([])

      assert {:ok, entries} = RescueTime.list_entries([@coding, @browsing], client: "key")

      assert entries["Code Editors"] == []
      assert entries["Web Browsers"] == []
    end

    test "excludes rows outside a sub-day :from/:to window despite the date-only query boundary" do
      rows = [
        ["2026-07-15 08:00:00", 600, 1, "Code Editors", "Software Development", 2],
        ["2026-07-15 14:00:00", 900, 1, "Code Editors", "Software Development", 2]
      ]

      stub_rows(rows)

      assert {:ok, entries} =
               RescueTime.list_entries([@coding],
                 client: "key",
                 from: ~U[2026-07-15 12:00:00Z],
                 to: ~U[2026-07-15 18:00:00Z]
               )

      assert [%{minutes: 15.0}] = entries["Code Editors"]
    end

    test "time_entry_id is stable across two calls given identical input rows" do
      rows = [["2026-07-15 08:00:00", 600, 1, "Code Editors", "Software Development", 2]]

      stub_rows(rows)
      assert {:ok, %{"Code Editors" => [entry1]}} = RescueTime.list_entries([@coding], client: "key")

      stub_rows(rows)
      assert {:ok, %{"Code Editors" => [entry2]}} = RescueTime.list_entries([@coding], client: "key")

      assert entry1.time_entry_id == entry2.time_entry_id
    end

    test "a non-2xx response returns {:error, _}" do
      Req.Test.stub(__MODULE__, fn conn ->
        Plug.Conn.send_resp(conn, 500, "boom")
      end)

      assert {:error, _reason} = RescueTime.list_entries([@coding], client: "key")
    end

    test "a transport error returns {:error, _}" do
      Req.Test.stub(__MODULE__, fn conn ->
        Req.Test.transport_error(conn, :timeout)
      end)

      assert {:error, _reason} = RescueTime.list_entries([@coding], client: "key")
    end
  end

  describe "list_sources/1" do
    test "returns :not_connected when no client is given" do
      assert {:error, :not_connected} = RescueTime.list_sources([])
    end

    test "maps distinct (Activity, Category) rank rows to sources, sorted case-insensitively" do
      rows = [
        [1, 6000, 1, "zsh", "Utilities"],
        [2, 3000, 1, "Code Editors", "Software Development"]
      ]

      stub_rows(rows)

      assert {:ok, sources} = RescueTime.list_sources(client: "key")

      assert sources == [
               %{id: "Code Editors", title: "Code Editors", ancestors: ["Software Development"], depth: 1},
               %{id: "zsh", title: "zsh", ancestors: ["Utilities"], depth: 1}
             ]
    end

    test "an empty rows response is {:ok, []}, not an error" do
      stub_rows([])

      assert {:ok, []} = RescueTime.list_sources(client: "key")
    end
  end
end
