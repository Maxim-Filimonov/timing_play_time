defmodule Mix.Tasks.Balance.Snapshot do
  @shortdoc "Prints a full Play Balance snapshot for one User, for debugging"

  @moduledoc """
  Recomputes and prints every figure PlayBalance derives for a single
  User — Play Balance (the debug-only, all-time truth), Playtime/Today's
  PT/Reserve/This Week (ADR-0010's windowed, ledger-based figures, with
  Spend Receipts), and each Activity's own Today/This Week breakdown.

  Runs against whatever code is on disk right now, freshly compiled —
  unlike a browser tab with an already-open LiveView socket, which keeps
  calling whatever code was loaded when it connected until a fresh HTTP
  request triggers a recompile (see the commit this task was added in).

  ## Usage

      mix balance.snapshot --user-id <uuid>
      mix balance.snapshot --cookie "<raw _timing_play_time_key cookie value>"
      mix balance.snapshot --user-id <uuid> --now 2026-08-08T09:33:00Z

  `--cookie` decodes the User straight from a raw session cookie value
  (copy it from the browser's dev tools, or have the User paste it) —
  handy for reproducing exactly what a specific User is seeing, without
  needing to look up their User id first. `--now` overrides "now"
  (defaults to the current time) — useful for replaying what a past
  moment's Entry Expiry Window would have shown.
  """

  use Mix.Task

  alias TimingPlayTime.Accounts
  alias TimingPlayTime.PlayBalance

  @persistence Application.compile_env!(:timing_play_time, :persistence_adapter)
  @time_source Application.compile_env!(:timing_play_time, :time_source_adapter)

  # Mirrors the `@session_options` in lib/timing_play_time_web/endpoint.ex —
  # keep these two salts in sync if that ever changes.
  @signing_salt "jwzC4Mcy"
  @encryption_salt "JxxTpi3H"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _rest, _invalid} =
      OptionParser.parse(args, strict: [user_id: :string, cookie: :string, now: :string])

    user = fetch_user!(opts)
    now = parse_now!(opts[:now])
    time_source_opts = connect_time_source(user)

    print_header(user, now)
    print_play_balance(user, time_source_opts)
    print_today(user, now, time_source_opts)
    print_activities(user, now, time_source_opts)
  end

  defp fetch_user!(opts) do
    user_id =
      case {opts[:user_id], opts[:cookie]} do
        {nil, nil} -> Mix.raise("pass --user-id <uuid> or --cookie \"<raw cookie value>\"")
        {user_id, nil} -> user_id
        {nil, cookie} -> decode_user_id!(cookie)
        {_, _} -> Mix.raise("pass only one of --user-id or --cookie")
      end

    case Accounts.get_user(user_id) do
      nil -> Mix.raise("no User found for id #{inspect(user_id)}")
      user -> user
    end
  end

  defp decode_user_id!(cookie) do
    secret_key_base =
      :timing_play_time
      |> Application.fetch_env!(TimingPlayTimeWeb.Endpoint)
      |> Keyword.fetch!(:secret_key_base)

    store_config =
      Plug.Session.COOKIE.init(signing_salt: @signing_salt, encryption_salt: @encryption_salt)

    conn = %Plug.Conn{secret_key_base: secret_key_base}

    case Plug.Session.COOKIE.get(conn, cookie, store_config) do
      {_sid, %{"user_id" => user_id}} -> user_id
      {_sid, %{user_id: user_id}} -> user_id
      _ -> Mix.raise("could not decode a user_id from that cookie value")
    end
  end

  defp parse_now!(nil), do: DateTime.utc_now()

  defp parse_now!(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _offset} -> dt
      {:error, reason} -> Mix.raise("invalid --now #{inspect(str)}: #{inspect(reason)}")
    end
  end

  defp connect_time_source(user) do
    case Accounts.get_integration(user) do
      nil ->
        []

      integration ->
        case @time_source.connect(integration.credentials) do
          {:ok, client} ->
            [client: client]

          {:error, reason} ->
            Mix.shell().info("(no Timing connection: #{inspect(reason)} — entries will be empty)")
            []
        end
    end
  end

  defp print_header(user, now) do
    Mix.shell().info("""

    == Play Balance snapshot ==
    User:     #{user.id}
    Timezone: #{user.timezone || "(unset)"}
    Now:      #{DateTime.to_iso8601(now)}
    Window:   #{DateTime.to_iso8601(PlayBalance.expiry_window_start(now))} .. #{DateTime.to_iso8601(now)}
    """)
  end

  defp print_play_balance(user, time_source_opts) do
    with {:ok, balance} <- PlayBalance.compute(user, time_source_opts) do
      Mix.shell().info("""
      -- Play Balance (debug, all-time, unbounded) --
      Timing-derived total: #{fmt(balance.timing_derived_total)}
      Manual sync total:    #{fmt(balance.manual_sync_total)}
      Playtime used total:  #{fmt(balance.playtime_used_total)}
      Total:                #{fmt(balance.total)}
      """)
    end
  end

  defp print_today(%{timezone: nil}, _now, _time_source_opts) do
    Mix.shell().info("-- Playtime -- (skipped: User has no timezone set)")
  end

  defp print_today(user, now, time_source_opts) do
    with {:ok, today} <- PlayBalance.compute_today(user, now, time_source_opts) do
      reconciled =
        today.week_earned - today.week_used + today.backlog_drawn + today.pushscroll_balance

      Mix.shell().info("""
      -- Playtime (windowed, ledger-based, ADR-0010) --
      Earned today:        #{fmt(today.earned_today)}
      Used today:          #{fmt(today.used_today)}
      This Week Earned:    #{fmt(today.week_earned)}
      This Week Used:      #{fmt(today.week_used)}
      Drawn from Backlog:  #{fmt(today.backlog_drawn)}
      Pushscroll Balance:  #{fmt(today.pushscroll_balance)}
      Today's PT:          #{fmt(today.today_net)}
      Reserve:             #{fmt(today.reserve)}
      Playtime:            #{fmt(today.playtime)}
      Reconciled (week_earned - week_used + backlog_drawn + pushscroll): #{fmt(reconciled)} #{if float_eq?(reconciled, today.playtime), do: "(matches)", else: "(MISMATCH!)"}

      Spend Receipts (#{length(today.receipts)}):
      """)

      Enum.each(today.receipts, fn receipt ->
        Mix.shell().info("  #{inspect(receipt.usage_id)}: #{inspect(receipt.breakdown)}")
      end)
    end
  end

  defp print_activities(%{timezone: nil}, _now, _time_source_opts) do
    Mix.shell().info("-- Activities -- (skipped: User has no timezone set)")
  end

  defp print_activities(user, now, time_source_opts) do
    with {:ok, activities} <- @persistence.list_activities(user.id) do
      Mix.shell().info("-- Activities (#{length(activities)}) --")

      get_elapsed_minutes = fn acts, opts -> @time_source.get_elapsed_minutes(acts, opts ++ time_source_opts) end
      list_entries = fn acts, opts -> @time_source.list_entries(acts, opts ++ time_source_opts) end

      Enum.each(activities, fn activity ->
        today = PlayBalance.today_activity_minutes(activity, user, now, get_elapsed_minutes)
        week = PlayBalance.week_activity_minutes(activity, now, list_entries)

        Mix.shell().info(
          "  #{activity.name} (x#{activity.multiplier}, #{activity.time_source_identifier}): " <>
            "today=#{fmt_result(today)} week=#{fmt_result(week)}"
        )
      end)
    end
  end

  defp fmt_result({:ok, %{play_minutes: minutes}}), do: fmt(minutes)
  defp fmt_result({:error, reason}), do: "error(#{inspect(reason)})"

  defp fmt(n) when is_float(n), do: :erlang.float_to_binary(n, decimals: 2)
  defp fmt(n), do: to_string(n)

  defp float_eq?(a, b), do: abs(a - b) < 0.001
end
