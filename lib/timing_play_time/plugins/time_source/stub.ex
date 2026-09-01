defmodule TimingPlayTime.Plugins.TimeSource.Stub do
  @moduledoc """
  Stub implementation of TimeSource for development and testing.

  Returns hardcoded time entries to simulate the Timing app without requiring MCP integration.

  Implements the same plural `get_elapsed_minutes/2` contract as the real
  Timing adapter, but isn't required to batch internally (ADR-0008) — it
  simply loops over the given Activities, computing each one's simulated
  minutes independently.
  """

  @behaviour TimingPlayTime.Plugins.TimeSource

  # A fixed 2-level hierarchy for the Source picker (ADR-0014), already in the
  # flat pre-order-DFS / alpha-within-level shape `list_sources/1` promises.
  # Every leaf id keeps a prefix `daily_rate/1` matches, so an Activity
  # created against a picked leaf still earns a simulated rate.
  @sources [
    %{id: "dev", title: "Development", ancestors: [], depth: 0},
    %{id: "coding-app", title: "App", ancestors: ["Development"], depth: 1},
    %{id: "writing-docs", title: "Docs", ancestors: ["Development"], depth: 1},
    %{id: "move", title: "Exercise", ancestors: [], depth: 0},
    %{id: "exercise-walk", title: "Walking", ancestors: ["Exercise"], depth: 1},
    %{id: "learn", title: "Learning", ancestors: [], depth: 0},
    %{id: "learning-elixir", title: "Elixir", ancestors: ["Learning"], depth: 1}
  ]

  @impl true
  def connect(credentials) when is_map(credentials), do: {:ok, :stub_client}

  # A non-map credential is the one way this stub reports a failed connection.
  # Keeping `connect/1` at the behaviour's full `{:ok, _} | {:error, _}` union
  # (rather than a body the checker folds to just `{:ok, :stub_client}`) is
  # also what keeps the `{:error, _}` branch reachable — and warning-free — at
  # the call sites that dispatch through the `compile_env`'d `@time_source`,
  # which is this Stub in `:test` but the real Timing adapter in prod.
  def connect(_credentials), do: {:error, :invalid_credentials}

  @impl true
  def list_sources(_opts), do: {:ok, @sources}

  @impl true
  def get_elapsed_minutes(activities, opts \\ [])

  def get_elapsed_minutes(activities, opts) do
    to = Keyword.get(opts, :to, DateTime.utc_now())
    today_from = Keyword.get(opts, :today_from)

    totals =
      Map.new(activities, fn activity ->
        cumulative = simulate_minutes(activity, activity.activated_at || to, to)
        today = if today_from, do: simulate_minutes(activity, today_from, to)

        {activity.time_source_identifier, %{cumulative: cumulative, today: today}}
      end)

    {:ok, totals}
  rescue
    error ->
      {:error, {:stub_error, error}}
  end

  # Fractional days elapsed in the queried range, so sub-day ranges (e.g.
  # "today so far") simulate proportional minutes instead of always zero.
  # Rate varies by time_source_identifier pattern to simulate different
  # projects.
  defp simulate_minutes(activity, from, to) do
    days_active = DateTime.diff(to, from, :second) / 86_400
    daily_rate(activity) * days_active
  end

  @doc """
  Test-only: forces every subsequent `list_entries/2` call to return
  `result` (e.g. `{:error, :timing_unavailable}`) until reset with `nil`.
  The simulation below can't fail on its own, so this is the only way to
  exercise a caller's time-source-outage path — notably
  `PlayBalance.log_spend/6`, which must refuse a spend rather than settle
  it against an empty pool (ADR-0012).
  """
  def fail_list_entries(result) do
    Application.put_env(:timing_play_time, :stub_list_entries_result, result)
    :ok
  end

  @impl true
  def list_entries(activities, opts \\ [])

  def list_entries(activities, opts) do
    case Application.get_env(:timing_play_time, :stub_list_entries_result) do
      nil -> simulate_list_entries(activities, opts)
      result -> result
    end
  end

  defp simulate_list_entries(activities, opts) do
    from = Keyword.get(opts, :from)
    to = Keyword.get(opts, :to, DateTime.utc_now())

    entries =
      Map.new(activities, fn activity ->
        {activity.time_source_identifier, simulate_entries(activity, from, to)}
      end)

    {:ok, entries}
  rescue
    error ->
      {:error, {:stub_error, error}}
  end

  # One synthetic entry per elapsed calendar day since `max(activated_at,
  # from)` (or a single same-day entry when both are unset), each worth a
  # full day's rate at that day's UTC midnight — real dated entries, unlike
  # get_elapsed_minutes/2's continuous day-fraction simulation, so the Entry
  # Consumption Ledger has something to expire and draw down. Respects an
  # explicit `:from` the same way the real Timing adapter does, so a
  # windowed fetch (ADR-0010) doesn't simulate entries the caller didn't ask
  # for.
  defp simulate_entries(activity, from, to) do
    lower_bound =
      case Enum.reject([activity.activated_at, from], &is_nil/1) do
        [] -> to
        candidates -> Enum.max(candidates, DateTime)
      end

    from_date = DateTime.to_date(lower_bound)
    to_date = DateTime.to_date(to)
    days = max(Date.diff(to_date, from_date), 0)
    rate = daily_rate(activity)

    for offset <- 0..days do
      start_date = from_date |> Date.add(offset) |> DateTime.new!(~T[00:00:00], "Etc/UTC")

      %{
        start_date: start_date,
        minutes: rate,
        time_entry_id: "#{activity.time_source_identifier}-#{DateTime.to_iso8601(start_date)}"
      }
    end
  end

  defp daily_rate(activity) do
    case activity.time_source_identifier do
      "coding-" <> _ -> 45.0
      "learning-" <> _ -> 42.0
      "exercise-" <> _ -> 36.0
      "writing-" <> _ -> 30.0
      _ -> 20.0
    end
  end
end
