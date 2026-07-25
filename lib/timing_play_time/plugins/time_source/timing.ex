defmodule TimingPlayTime.Plugins.TimeSource.Timing do
  @moduledoc """
  TimeSource adapter backed by the Timing MCP server, per ADR-0002
  (https://web.timingapp.com/docs/#using-ai-tools-with-mcp).

  Calls the `list_time_entries` tool for the Activity's mapped Timing
  Project and sums entry durations (seconds) into minutes.
  """

  @behaviour TimingPlayTime.Plugins.TimeSource

  @mcp_url "https://web.timingapp.com/mcp"

  def child_spec(opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}
  end

  def start_link(_opts) do
    ExMCP.Client.start_link(
      transport: :http,
      url: @mcp_url,
      auth_provider: {ExMCP.Authorization.Provider.Static, token: api_key()},
      security: %{tls: %{cacerts: castore_cacerts()}},
      name: __MODULE__
    )
  end

  @impl true
  def get_elapsed_minutes(activity, opts \\ []) do
    client = Keyword.get(opts, :client, __MODULE__)
    from = Keyword.get(opts, :from, activity.activated_at || DateTime.utc_now())
    to = Keyword.get(opts, :to, DateTime.utc_now())

    arguments = %{
      "projects" => [activity.time_source_identifier],
      "start_date_min" => DateTime.to_iso8601(from),
      "start_date_max" => DateTime.to_iso8601(to)
    }

    with {:ok, response} <- ExMCP.Client.call_tool(client, "list_time_entries", arguments),
         {:ok, entries} <- extract_entries(response) do
      total_seconds = Enum.reduce(entries, 0, fn entry, acc -> acc + duration_seconds(entry) end)
      {:ok, total_seconds / 60}
    end
  end

  defp extract_entries(%ExMCP.Response{is_error: true} = response) do
    {:error, {:tool_error, ExMCP.Response.text_content(response)}}
  end

  defp extract_entries(%ExMCP.Response{structuredOutput: structured})
       when not is_nil(structured) do
    {:ok, entries_from(structured)}
  end

  defp extract_entries(%ExMCP.Response{} = response) do
    case ExMCP.Response.text_content(response) do
      nil ->
        {:error, :empty_tool_result}

      text ->
        case Jason.decode(text) do
          {:ok, decoded} -> {:ok, entries_from(decoded)}
          {:error, reason} -> {:error, {:invalid_tool_result, reason}}
        end
    end
  end

  defp entries_from(%{"data" => entries}) when is_list(entries), do: entries
  defp entries_from(entries) when is_list(entries), do: entries
  defp entries_from(_), do: []

  defp duration_seconds(%{"duration" => duration}) when is_number(duration), do: duration
  defp duration_seconds(_), do: 0

  defp api_key do
    Application.get_env(:timing_play_time, __MODULE__, [])
    |> Keyword.fetch!(:api_key)
  end

  # ExMCP's HTTP transport defaults to `:public_key.cacerts_get/0` for the CA
  # bundle, which relies on the OS exposing its trust store to the BEAM in a
  # way it doesn't always do (yields `cacerts: :undefined`, an invalid :ssl
  # option combo). Loading castore's bundled CAs sidesteps the OS lookup.
  defp castore_cacerts do
    CAStore.file_path()
    |> File.read!()
    |> :public_key.pem_decode()
    |> Enum.map(fn {:Certificate, der, _} -> der end)
  end
end
