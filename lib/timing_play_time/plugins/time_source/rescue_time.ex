defmodule TimingPlayTime.Plugins.TimeSource.RescueTime do
  @moduledoc """
  TimeSource adapter backed by RescueTime's free Lite-tier Data API
  (ADR-0016).

  Unlike the Timing adapter (an MCP client), this talks to RescueTime's
  plain HTTP Data API directly via `Req`. `connect/1` never makes a network
  call — the returned `{:ok, api_key}` handle is the bare key string itself,
  passed back in as `opts[:client]` by every other callback, the same
  handle convention `Timing` uses for its MCP client.

  `get_elapsed_minutes/2` and `list_entries/2` share one query shape
  (`perspective=interval&resolution_time=hour`, `restrict_thing` always
  omitted so every Activity is batched into one call — ADR-0009). RescueTime
  only accepts date-only `restrict_begin`/`restrict_end` bounds (no
  time-of-day), so a sub-day `:from`/`:to` window is widened to its
  containing calendar days for the query, then rows are re-filtered against
  the original bounds — this is what keeps the widened query from leaking
  out-of-range rows into the result.
  """

  @behaviour TimingPlayTime.Plugins.TimeSource

  require Logger

  @base_url "https://www.rescuetime.com/anapi/data"

  # list_sources/1's lookback window — RescueTime Lite can't return anything
  # older than its own history cap regardless (ADR-0016's residual risk), so
  # asking further back buys nothing.
  @lookback_days 14

  # Stands in for "no floor" on list_entries/2's fetch (ADR-0010), mirroring
  # Timing's own @beginning_of_time.
  @beginning_of_time ~U[1970-01-01 00:00:00Z]

  @impl true
  def connect(%{"api_key" => api_key}) when is_binary(api_key), do: {:ok, api_key}
  def connect(_credentials), do: {:error, :invalid_credentials}

  @impl true
  def list_sources(opts \\ [])

  def list_sources(opts) do
    case Keyword.get(opts, :client) do
      nil -> {:error, :not_connected}
      api_key -> do_list_sources(api_key)
    end
  end

  defp do_list_sources(api_key) do
    today = Date.utc_today()

    params = [
      restrict_kind: "activity",
      perspective: "rank",
      restrict_begin: Date.to_iso8601(Date.add(today, -@lookback_days)),
      restrict_end: Date.to_iso8601(today)
    ]

    with {:ok, rows} <- request(api_key, params, "list_sources") do
      {:ok, sources_from_rows(rows)}
    end
  end

  # Distinct (Activity, Category) pairs from the rank rows become sources,
  # each Category the sole `ancestors` entry (`depth: 1`) — RescueTime has no
  # deeper hierarchy to walk, unlike Timing's arbitrary-depth Projects.
  defp sources_from_rows(rows) do
    rows
    |> Enum.map(&{row_activity(&1), row_category(&1)})
    |> Enum.uniq()
    |> Enum.map(fn {activity, category} ->
      %{id: activity, title: activity, ancestors: [category], depth: 1}
    end)
    |> Enum.sort_by(&String.downcase(&1.title))
  end

  @impl true
  def get_elapsed_minutes(activities, opts \\ [])

  def get_elapsed_minutes([], _opts), do: {:ok, %{}}

  def get_elapsed_minutes(activities, opts) do
    case Keyword.get(opts, :client) do
      nil -> {:error, :not_connected}
      api_key -> do_get_elapsed_minutes(activities, api_key, opts)
    end
  end

  defp do_get_elapsed_minutes(activities, api_key, opts) do
    from = TimingPlayTime.Plugins.TimeSource.earliest_activation_from(activities)
    to = Keyword.get(opts, :to, DateTime.utc_now())
    today_from = Keyword.get(opts, :today_from)

    with {:ok, rows} <- fetch_interval_rows(api_key, from, to, "get_elapsed_minutes") do
      matched = rows |> in_activity_set(activities) |> rows_in_range(from, to)
      {:ok, bucket_rows(matched, activities, today_from)}
    end
  end

  @impl true
  def list_entries(activities, opts \\ [])

  def list_entries([], _opts), do: {:ok, %{}}

  def list_entries(activities, opts) do
    case Keyword.get(opts, :client) do
      nil -> {:error, :not_connected}
      api_key -> do_list_entries(activities, api_key, opts)
    end
  end

  defp do_list_entries(activities, api_key, opts) do
    from = Keyword.get(opts, :from, @beginning_of_time)
    to = Keyword.get(opts, :to, DateTime.utc_now())

    with {:ok, rows} <- fetch_interval_rows(api_key, from, to, "list_entries") do
      matched = rows |> in_activity_set(activities) |> rows_in_range(from, to)
      {:ok, entries_by_identifier(matched, activities)}
    end
  end

  # RescueTime's restrict_begin/restrict_end are date-only (no time-of-day) —
  # the query is widened to the containing calendar days; `rows_in_range/3`
  # re-filters against the original bounds afterwards, which is what makes
  # this widening safe.
  defp fetch_interval_rows(api_key, from, to, log_prefix) do
    params = [
      restrict_kind: "activity",
      perspective: "interval",
      resolution_time: "hour",
      restrict_begin: Date.to_iso8601(DateTime.to_date(from)),
      restrict_end: Date.to_iso8601(DateTime.to_date(to))
    ]

    request(api_key, params, log_prefix)
  end

  defp in_activity_set(rows, activities) do
    identifiers = MapSet.new(activities, & &1.time_source_identifier)
    Enum.filter(rows, &MapSet.member?(identifiers, row_activity(&1)))
  end

  defp rows_in_range(rows, from, to) do
    Enum.filter(rows, fn row ->
      case row_date(row) do
        nil -> false
        date -> DateTime.compare(date, from) != :lt and DateTime.compare(date, to) != :gt
      end
    end)
  end

  defp bucket_rows(rows, activities, today_from) do
    empty = fn -> %{cumulative: 0, today: if(today_from, do: 0, else: nil)} end

    grouped =
      Enum.reduce(rows, %{}, fn row, acc ->
        identifier = row_activity(row)
        current = Map.get(acc, identifier, empty.())
        Map.put(acc, identifier, add_row(current, row, today_from))
      end)

    activities
    |> Enum.reduce(grouped, fn activity, acc ->
      Map.put_new_lazy(acc, activity.time_source_identifier, empty)
    end)
    |> Map.new(fn {id, %{cumulative: cumulative, today: today}} ->
      {id, %{cumulative: cumulative / 60, today: if(today, do: today / 60, else: nil)}}
    end)
  end

  defp add_row(%{cumulative: cumulative, today: today}, row, today_from) do
    seconds = row_seconds(row)

    today =
      case {today, today_from, row_date(row)} do
        {nil, _, _} -> nil
        {today, today_from, date} when not is_nil(date) ->
          if DateTime.compare(date, today_from) != :lt, do: today + seconds, else: today

        {today, _, _} ->
          today
      end

    %{cumulative: cumulative + seconds, today: today}
  end

  defp entries_by_identifier(rows, activities) do
    grouped =
      Enum.reduce(rows, %{}, fn row, acc ->
        identifier = row_activity(row)
        entry = dated_entry(row)
        Map.update(acc, identifier, [entry], &[entry | &1])
      end)

    Enum.reduce(activities, grouped, fn activity, acc ->
      Map.put_new(acc, activity.time_source_identifier, [])
    end)
  end

  defp dated_entry(row) do
    raw_date = row_raw_date(row)
    activity = row_activity(row)

    %{
      start_date: parse_row_date(raw_date),
      minutes: row_seconds(row) / 60,
      time_entry_id: time_entry_id(activity, raw_date)
    }
  end

  # A synthesized, stable id for the Entry Consumption Ledger (ADR-0012) —
  # RescueTime's interval rows carry no id of their own — truncated to 16
  # hex chars, same convention a persisted `:string` column expects.
  defp time_entry_id(activity_name, raw_date) do
    :crypto.hash(:sha256, activity_name <> "|" <> raw_date)
    |> Base.encode16(case: :lower)
    |> String.slice(0, 16)
  end

  # Row shapes (RescueTime Data API):
  #   perspective=rank:     [Rank, "Time Spent (seconds)", "Number of People", Activity, Category]
  #   perspective=interval: [Date, "Time Spent (seconds)", "Number of People", Activity, Category, Productivity]
  # Activity/Category share the same positions (index 3/4) in both shapes.
  defp row_raw_date([date | _rest]), do: date
  defp row_seconds([_first, seconds | _rest]) when is_number(seconds), do: seconds
  defp row_seconds(_row), do: 0
  defp row_activity([_first, _seconds, _people, activity | _rest]), do: activity
  defp row_category([_first, _seconds, _people, _activity, category | _rest]), do: category
  defp row_category(_row), do: ""

  defp row_date(row), do: row |> row_raw_date() |> parse_row_date()

  # RescueTime interval rows carry a naive local timestamp with no UTC
  # offset (confirmed via research #37) — documented-but-unverified as
  # account-local (ADR-0016's residual risk). Treated as already being in
  # whatever zone the account's timestamps are in: parsed as naive, then
  # attached to Etc/UTC rather than converted — a deliberate, visible
  # placeholder a future timezone-calibration pass can correct.
  defp parse_row_date(date_str) do
    normalized = String.replace(date_str, " ", "T", global: false)

    case NaiveDateTime.from_iso8601(normalized) do
      {:ok, naive} -> DateTime.from_naive!(naive, "Etc/UTC")
      {:error, _reason} -> nil
    end
  end

  defp request(api_key, params, log_prefix) do
    case Req.get(build_req(api_key), params: params) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        {:ok, rows_from(body)}

      {:ok, %Req.Response{status: status}} ->
        Logger.warning("RescueTime.#{log_prefix}: non-2xx response: #{status}")
        {:error, {:http_error, status}}

      {:error, reason} ->
        Logger.warning("RescueTime.#{log_prefix}: request failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp rows_from(%{"rows" => rows}) when is_list(rows), do: rows
  defp rows_from(_other), do: []

  defp build_req(api_key) do
    base = Req.new(base_url: @base_url, params: [key: api_key, format: "json"], retry: false)

    case Application.get_env(:timing_play_time, :rescuetime_req_plug) do
      nil -> base
      plug -> Req.merge(base, plug: plug)
    end
  end
end
