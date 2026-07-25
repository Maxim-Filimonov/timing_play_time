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
        %{
          "content" => [
            %{"type" => "text", "text" => Jason.encode!(%{"data" => state[:entries] || []})}
          ]
        }
    end
  end
end
