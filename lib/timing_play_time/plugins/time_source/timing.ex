defmodule TimingPlayTime.Plugins.TimeSource.Timing do
  @moduledoc """
  TimeSource adapter backed by the Timing MCP server, per ADR-0002
  (https://web.timingapp.com/docs/#using-ai-tools-with-mcp).

  Issues one `list_time_entries` call per invocation covering every given
  Activity's mapped Timing Project at once (ADR-0008), rather than one call
  per Activity, then buckets the returned entries back to each Activity by
  matching its Project.

  Per ADR-0007, there is no boot-time singleton connection holding one
  global API key — `connect/1` opens a connection per call to `credentials`
  (a User's Integration, `%{"api_key" => "..."}"`), and the caller (the
  dashboard LiveView) owns that connection's lifetime.
  """

  @behaviour TimingPlayTime.Plugins.TimeSource

  require Logger

  @mcp_url "https://web.timingapp.com/mcp"

  # Timing's documented single-page cap for `list_time_entries`.
  @page_size_limit 1000

  @impl true
  def connect(credentials) do
    ExMCP.Client.start_link(
      transport: :http,
      url: @mcp_url,
      auth_provider: {ExMCP.Authorization.Provider.Static, token: Map.fetch!(credentials, "api_key")},
      security: %{tls: %{cacerts: castore_cacerts()}},
      # ex_mcp 1.0.0-rc.4's SSE-reconnect path (ExMCP.Transport.SSEClient) wraps
      # the already-wrapped `security.tls` ssl_opts a second time, producing a
      # malformed :ssl option list that ignores our cacerts override above and
      # falls back to the OS cacerts lookup, which fails here. We only ever
      # make request/response tool calls (no server-initiated push), so the
      # SSE stream isn't needed and disabling it sidesteps the bug.
      use_sse: false
    )
  end

  @impl true
  def get_elapsed_minutes(activities, opts \\ [])

  def get_elapsed_minutes([], _opts), do: {:ok, %{}}

  def get_elapsed_minutes(activities, opts) do
    case Keyword.get(opts, :client) do
      nil -> {:error, :not_connected}
      client -> do_get_elapsed_minutes(activities, client, opts)
    end
  end

  defp do_get_elapsed_minutes(activities, client, opts) do
    from = earliest_from(activities)
    to = Keyword.get(opts, :to, DateTime.utc_now())
    today_from = Keyword.get(opts, :today_from)
    projects = Enum.map(activities, & &1.time_source_identifier)

    Logger.info(
      "Timing.get_elapsed_minutes: calling list_time_entries " <>
        "projects=#{inspect(projects)} from=#{iso8601_no_microseconds(from)} " <>
        "to=#{iso8601_no_microseconds(to)}"
    )

    with {:ok, entries} <- fetch_all_entries(client, projects, from, to) do
      totals = bucket_entries(entries, activities, today_from)

      entry_word = if length(entries) == 1, do: "y", else: "ies"
      project_word = if length(projects) == 1, do: "", else: "s"

      Logger.info(
        "Timing.get_elapsed_minutes: fetched #{length(entries)} entr#{entry_word} " <>
          "across #{length(projects)} project#{project_word}"
      )

      {:ok, totals}
    else
      {:error, reason} = error ->
        Logger.warning(
          "Timing.get_elapsed_minutes: list_time_entries call failed: #{inspect(reason)}"
        )

        error
    end
  end

  # The earliest of each given Activity's own default "from" (the beginning
  # of the calendar day it was activated) — the shared cutoff this batched
  # fetch uses instead of a distinct one per Activity (ADR-0008).
  defp earliest_from(activities) do
    activities |> Enum.map(&default_from(&1.activated_at)) |> earliest()
  end

  defp earliest(datetimes) do
    Enum.reduce(datetimes, fn a, b -> if DateTime.compare(a, b) == :lt, do: a, else: b end)
  end

  # Fetches every entry across the full [start_min, start_max] range,
  # paginating backward when a page returns the maximum @page_size_limit
  # entries: re-queries with `start_date_max` set to just before the oldest
  # entry seen in that page (entries are ordered descending by start_date),
  # repeating until a page returns fewer than @page_size_limit or coverage
  # reaches the original `start_min`.
  defp fetch_all_entries(client, projects, start_min, start_max) do
    fetch_all_entries(client, projects, start_min, start_max, [])
  end

  defp fetch_all_entries(client, projects, start_min, start_max, acc) do
    arguments = %{
      "projects" => projects,
      "start_date_min" => iso8601_no_microseconds(start_min),
      "start_date_max" => iso8601_no_microseconds(start_max)
    }

    with {:ok, response} <- ExMCP.Client.call_tool(client, "list_time_entries", arguments),
         {:ok, entries} <- extract_entries(response) do
      acc = acc ++ entries

      if length(entries) >= @page_size_limit do
        paginate_further(client, projects, start_min, entries, acc)
      else
        {:ok, acc}
      end
    end
  end

  defp paginate_further(client, projects, start_min, page_entries, acc) do
    case oldest_start_date(page_entries) do
      nil ->
        {:ok, acc}

      oldest ->
        next_max = DateTime.add(oldest, -1, :second)

        if DateTime.compare(next_max, start_min) != :gt do
          {:ok, acc}
        else
          fetch_all_entries(client, projects, start_min, next_max, acc)
        end
    end
  end

  defp oldest_start_date(entries) do
    entries
    |> Enum.map(&parse_datetime(&1["start_date"]))
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> nil
      dates -> earliest(dates)
    end
  end

  # Buckets fetched entries back to each Activity by matching Project
  # identifiers (normalized — see `strip_projects_prefix/1`), then splits
  # each Activity's matched entries into `cumulative` (all of them) and
  # `today` (entries at or after `today_from`, or `nil` throughout if
  # `today_from` wasn't given).
  defp bucket_entries(entries, activities, today_from) do
    activity_by_project_id =
      Map.new(activities, fn activity ->
        {strip_projects_prefix(activity.time_source_identifier), activity.time_source_identifier}
      end)

    empty = fn -> %{cumulative: 0, today: if(today_from, do: 0, else: nil)} end

    totals =
      Enum.reduce(entries, %{}, fn entry, totals ->
        case Map.fetch(activity_by_project_id, project_id_from_entry(entry)) do
          :error ->
            totals

          {:ok, identifier} ->
            Map.update(totals, identifier, add_entry(empty.(), entry, today_from), fn bucket ->
              add_entry(bucket, entry, today_from)
            end)
        end
      end)

    # Activities with no matching entries at all still get a zeroed bucket,
    # rather than being absent from the returned map.
    Enum.reduce(activities, totals, fn activity, totals ->
      Map.put_new_lazy(totals, activity.time_source_identifier, empty)
    end)
    |> Map.new(fn {id, %{cumulative: cumulative, today: today}} ->
      {id, %{cumulative: cumulative / 60, today: if(today, do: today / 60, else: nil)}}
    end)
  end

  defp add_entry(%{cumulative: cumulative, today: today}, entry, today_from) do
    seconds = duration_seconds(entry)

    today =
      case {today, today_from} do
        {nil, _} -> nil
        {today, today_from} -> if entry_after?(entry, today_from), do: today + seconds, else: today
      end

    %{cumulative: cumulative + seconds, today: today}
  end

  defp entry_after?(entry, cutoff) do
    case parse_datetime(entry["start_date"]) do
      nil -> false
      start_date -> DateTime.compare(start_date, cutoff) != :lt
    end
  end

  defp project_id_from_entry(entry) do
    entry |> get_in(["project", "self"]) |> strip_projects_prefix()
  end

  defp strip_projects_prefix(nil), do: nil
  defp strip_projects_prefix("/projects/" <> id), do: id
  defp strip_projects_prefix(id), do: id

  defp parse_datetime(nil), do: nil

  defp parse_datetime(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _offset} -> dt
      {:error, _reason} -> nil
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

  defp entries_from(%{"time_entries" => entries}) when is_list(entries) do
    Logger.debug(fn -> "Timing entries_from: matched %{\"time_entries\" => list} shape" end)
    entries
  end

  defp entries_from(entries) when is_list(entries) do
    Logger.debug(fn -> "Timing entries_from: matched bare list shape" end)
    entries
  end

  defp entries_from(other) do
    Logger.warning(
      "Timing entries_from: unrecognised tool result shape, treating as zero entries: #{inspect(other)}"
    )

    []
  end

  defp duration_seconds(%{"duration" => duration}) when is_number(duration), do: duration
  defp duration_seconds(_), do: 0

  # Cutoff for entries defaults to the beginning of the day the Activity was
  # activated, not the exact activation instant, so an Activity created mid-day
  # still counts time already logged earlier that same day.
  defp default_from(nil), do: DateTime.utc_now()

  defp default_from(%DateTime{} = activated_at) do
    DateTime.new!(DateTime.to_date(activated_at), ~T[00:00:00], activated_at.time_zone)
  end

  # Timing's MCP docs require dates "without microseconds" (e.g.
  # "2019-01-01T00:00:00+00:00"); DateTime.utc_now()'s default microsecond
  # precision violates that, which a narrow same-day range is more exposed to
  # than the wide since-activation range (silently filtered to no matches).
  defp iso8601_no_microseconds(datetime) do
    datetime |> DateTime.truncate(:second) |> DateTime.to_iso8601()
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
