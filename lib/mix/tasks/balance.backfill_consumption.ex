defmodule Mix.Tasks.Balance.BackfillConsumption do
  @shortdoc "One-time backfill of the persisted Entry Consumption Ledger (ADR-0012)"

  @moduledoc """
  Replays a User's full, unwindowed entry and usage history under the OLD
  unbounded-overflow rule (pure oldest-first FIFO, no window prioritization
  — `EntryLedger.replay/4` with `window_start: nil`) and persists the
  resulting per-entry consumption via `record_entry_consumption/4`.

  This is the one-time migration ADR-0012 calls for: without it, a User's
  existing entries all read as fully unspent under the new persisted
  ledger, even ones a spend genuinely already drew on — this task seeds
  the ledger with what actually happened historically, correcting the
  live-replay bug's inflated figures once, rather than starting the new
  design from a wrong baseline.

  **Not idempotent** — `record_entry_consumption/4` always adds to
  whatever's already there, so running this twice for the same User would
  double-count. Refuses to run against a User who already has any
  consumption rows, unless `--dry-run` is given.

  ## Usage

      mix balance.backfill_consumption --user-id <uuid>
      mix balance.backfill_consumption --cookie "<raw _timing_play_time_key cookie value>"
      mix balance.backfill_consumption --user-id <uuid> --dry-run
  """

  use Mix.Task

  alias TimingPlayTime.Accounts
  alias TimingPlayTime.EntryLedger
  alias TimingPlayTime.PlaytimeUsed

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
      OptionParser.parse(args, strict: [user_id: :string, cookie: :string, dry_run: :boolean])

    user = fetch_user!(opts)
    dry_run? = !!opts[:dry_run]
    time_source_opts = connect_time_source(user)

    with {:ok, activities} <- @persistence.list_activities(user.id),
         {:ok, usages} <- PlaytimeUsed.list_all(user.id),
         {:ok, existing} <- @persistence.list_entry_consumption(user.id) do
      unless dry_run? or existing == [] do
        Mix.raise("""
        User #{user.id} already has #{length(existing)} entry consumption row(s).
        This task is not idempotent — running it again would double-count \
        already-persisted consumption. Refusing (pass --dry-run to inspect \
        without writing).
        """)
      end

      raw_entries = EntryLedger.load(activities, DateTime.utc_now(), time_source_opts)
      ledger_entries = build_ledger_entries(activities, raw_entries)

      %{entries: replayed} = EntryLedger.replay(ledger_entries, usages, user.timezone)

      to_backfill =
        replayed
        |> Enum.map(&{&1.activity_id, &1.time_entry_id, &1.play_minutes - &1.remaining})
        |> Enum.filter(fn {_activity_id, _time_entry_id, consumed} -> consumed > 0.0 end)

      Mix.shell().info(
        "#{length(to_backfill)} of #{length(replayed)} entries have consumption to backfill."
      )

      if dry_run? do
        Enum.each(to_backfill, fn {activity_id, time_entry_id, minutes} ->
          Mix.shell().info(
            "  (dry run) activity=#{activity_id} entry=#{inspect(time_entry_id)}: #{Float.round(minutes, 1)}"
          )
        end)
      else
        Enum.each(to_backfill, fn {activity_id, time_entry_id, minutes} ->
          {:ok, _total} = @persistence.record_entry_consumption(user.id, activity_id, time_entry_id, minutes)
        end)

        Mix.shell().info("Backfilled #{length(to_backfill)} entries for User #{user.id}.")
      end
    end
  end

  # Mirrors PlayBalance's own private build_ledger_entries/2 — duplicated
  # rather than exposed publicly from PlayBalance, since this task needs
  # full unwindowed history (backfill's whole point) where PlayBalance's
  # callers always want the window-bounded kind.
  defp build_ledger_entries(activities, raw_entries_by_identifier) do
    Enum.flat_map(activities, fn activity ->
      raw_entries_by_identifier
      |> Map.get(activity.time_source_identifier, [])
      |> Enum.map(fn raw_entry ->
        %{
          activity_id: activity.id,
          time_entry_id: Map.get(raw_entry, :time_entry_id) || raw_entry.start_date,
          start_date: raw_entry.start_date,
          play_minutes: raw_entry.minutes * activity.multiplier
        }
      end)
    end)
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
end
