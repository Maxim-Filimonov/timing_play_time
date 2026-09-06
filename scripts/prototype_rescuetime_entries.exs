# PROTOTYPE — throwaway, lives only on branch prototype/rescuetime-entry-bucketing.
# Answers issue #39 (part of map #36): how does list_entries/2's discrete-row
# contract map onto RescueTime's aggregated-bucket Data API?
#
# Run: mix run scripts/prototype_rescuetime_entries.exs
# Requires RESCUETIME_API_KEY in .env (gitignored, real account, read-only key).

Application.ensure_all_started(:req)

env =
  ".env"
  |> File.read!()
  |> String.split("\n", trim: true)
  |> Map.new(fn line -> [k, v] = String.split(line, "=", parts: 2); {k, v} end)

api_key = Map.fetch!(env, "RESCUETIME_API_KEY")

fetch = fn params ->
  %{status: status, body: body} =
    Req.get!("https://www.rescuetime.com/anapi/data",
      params: Map.merge(%{key: api_key, format: "json"}, params)
    )

  {status, body}
end

print_state = fn label, data ->
  IO.puts("\n=== #{label} ===")
  IO.inspect(data, limit: 20, pretty: true)
end

# --- Q1 + timezone risk: resolution_time=hour, real data, across a day boundary ---
{status, body} =
  fetch.(%{
    restrict_kind: "activity",
    perspective: "interval",
    resolution_time: "hour",
    restrict_begin: Date.utc_today() |> Date.add(-2) |> Date.to_iso8601(),
    restrict_end: Date.utc_today() |> Date.to_iso8601()
  })

print_state.("Q1/timezone: hourly activity rows, last 2 days (status #{status})", body)

# --- Q3: batching — omit restrict_thing, get everything for restrict_kind=activity ---
{status, body} =
  fetch.(%{
    restrict_kind: "activity",
    perspective: "interval",
    resolution_time: "hour",
    restrict_begin: Date.utc_today() |> Date.add(-1) |> Date.to_iso8601(),
    restrict_end: Date.utc_today() |> Date.to_iso8601()
  })

print_state.("Q3: batched all-activities response, single call (status #{status})", body)

distinct_activities =
  case body do
    %{"rows" => rows, "row_headers" => headers} ->
      activity_idx = Enum.find_index(headers, &(&1 == "Activity"))
      rows |> Enum.map(&Enum.at(&1, activity_idx)) |> Enum.uniq()

    _ ->
      []
  end

print_state.("Q3: distinct activity names present in one batched call", distinct_activities)

# --- Q2: synthesize a stable pseudo-entry id from (activity, bucket start) ---
synthesize_id = fn activity_name, bucket_start_str ->
  :crypto.hash(:sha256, activity_name <> "|" <> bucket_start_str)
  |> Base.encode16(case: :lower)
  |> String.slice(0, 16)
end

sample_ids =
  case body do
    %{"rows" => rows, "row_headers" => headers} ->
      date_idx = Enum.find_index(headers, &(&1 == "Date"))
      activity_idx = Enum.find_index(headers, &(&1 == "Activity"))

      rows
      |> Enum.take(5)
      |> Enum.map(fn row ->
        raw_date = Enum.at(row, date_idx)
        activity = Enum.at(row, activity_idx)
        {activity, raw_date, synthesize_id.(activity, raw_date)}
      end)

    _ ->
      []
  end

print_state.("Q2: sample (activity, raw bucket timestamp, synthesized id)", sample_ids)

# Re-run the identical query to confirm id stability across calls
{_status2, body2} = fetch.(%{
  restrict_kind: "activity",
  perspective: "interval",
  resolution_time: "hour",
  restrict_begin: Date.utc_today() |> Date.add(-1) |> Date.to_iso8601(),
  restrict_end: Date.utc_today() |> Date.to_iso8601()
})

stability_check =
  case body2 do
    %{"rows" => rows, "row_headers" => headers} ->
      date_idx = Enum.find_index(headers, &(&1 == "Date"))
      activity_idx = Enum.find_index(headers, &(&1 == "Activity"))

      rows
      |> Enum.take(5)
      |> Enum.map(fn row ->
        raw_date = Enum.at(row, date_idx)
        activity = Enum.at(row, activity_idx)
        synthesize_id.(activity, raw_date)
      end)

    _ ->
      []
  end

print_state.("Q2: same ids on identical re-fetch? (compare to previous block)", stability_check)

# --- Q4: out-of-range request beyond RescueTime Lite's 2-week cap ---
{status, body} =
  fetch.(%{
    restrict_kind: "activity",
    perspective: "interval",
    resolution_time: "hour",
    restrict_begin: Date.utc_today() |> Date.add(-60) |> Date.to_iso8601(),
    restrict_end: Date.utc_today() |> Date.add(-45) |> Date.to_iso8601()
  })

print_state.("Q4: request 45-60 days ago, past the 2-week Lite cap (status #{status})", body)

# --- Q4 control: request exactly at the 13-day boundary (inside the cap) ---
{status, body} =
  fetch.(%{
    restrict_kind: "activity",
    perspective: "interval",
    resolution_time: "hour",
    restrict_begin: Date.utc_today() |> Date.add(-13) |> Date.to_iso8601(),
    restrict_end: Date.utc_today() |> Date.add(-12) |> Date.to_iso8601()
  })

print_state.("Q4 control: request 12-13 days ago, inside the cap (status #{status})", body)
