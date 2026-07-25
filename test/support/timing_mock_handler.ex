defmodule TimingPlayTime.Support.TimingMockHandler do
  @moduledoc """
  `ExMCP.Testing.MockServer` `:handler` double standing in for the real Timing
  MCP server, used to test `TimingPlayTime.Plugins.TimeSource.Timing`.
  """

  def call_tool(tool_name, arguments, state) do
    if pid = state[:test_pid], do: send(pid, {:call_tool, tool_name, arguments})

    cond do
      state[:error] ->
        %{"isError" => true, "content" => [%{"type" => "text", "text" => state.error}]}

      state[:raw_text] ->
        %{"content" => [%{"type" => "text", "text" => state.raw_text}]}

      true ->
        entries = filter_by_date_range(state[:entries] || [], arguments)

        %{
          "content" => [
            %{
              "type" => "text",
              "text" =>
                Jason.encode!(%{
                  "time_entries" => entries,
                  "projects" => [],
                  "teams" => []
                })
            }
          ]
        }
    end
  end

  # Simulates the real Timing server's start_date_min/max filtering, so tests
  # can catch date-range bugs. Entries without a "start_date" key (most
  # existing tests) are unaffected — they always match, regardless of range.
  defp filter_by_date_range(entries, arguments) do
    min = parse_datetime(arguments["start_date_min"])
    max = parse_datetime(arguments["start_date_max"])

    Enum.filter(entries, fn entry ->
      case entry["start_date"] do
        nil ->
          true

        start_date ->
          entry_dt = parse_datetime(start_date)
          not_before?(entry_dt, min) and not_after?(entry_dt, max)
      end
    end)
  end

  defp not_before?(_entry_dt, nil), do: true
  defp not_before?(entry_dt, min), do: DateTime.compare(entry_dt, min) != :lt

  defp not_after?(_entry_dt, nil), do: true
  defp not_after?(entry_dt, max), do: DateTime.compare(entry_dt, max) != :gt

  defp parse_datetime(nil), do: nil

  defp parse_datetime(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _offset} -> dt
      {:error, _reason} -> nil
    end
  end
end
