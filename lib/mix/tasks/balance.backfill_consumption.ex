defmodule Mix.Tasks.Balance.BackfillConsumption do
  @shortdoc "One-time backfill of the persisted Entry Consumption Ledger (ADR-0012)"

  @moduledoc """
  Replays a User's full, unwindowed entry and usage history under the OLD
  unbounded-overflow rule (pure oldest-first FIFO, no window prioritization
  — `EntryLedger.replay/4` with `window_start: nil`) and persists the
  resulting per-entry consumption via `record_entry_consumptions/2`, as one
  atomic batch.

  This is the one-time migration ADR-0012 calls for: without it, a User's
  existing entries all read as fully unspent under the new persisted
  ledger, even ones a spend genuinely already drew on — this task seeds
  the ledger with what actually happened historically, correcting the
  live-replay bug's inflated figures once, rather than starting the new
  design from a wrong baseline.

  **Not idempotent** — a consumption write always adds to
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
  alias TimingPlayTime.Plugins.TimeSource

  @persistence Application.compile_env!(:timing_play_time, :persistence_adapter)

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
    {module, time_source_opts} = connect_time_source(user)

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

      raw_entries =
        EntryLedger.load(activities, DateTime.utc_now(), time_source_opts, &module.list_entries/2)
      ledger_entries = EntryLedger.build_entries(activities, raw_entries)

      %{entries: replayed} = EntryLedger.replay(ledger_entries, usages, user.timezone)

      to_backfill =
        replayed
        |> Enum.map(
          &%{
            activity_id: &1.activity_id,
            time_entry_id: &1.time_entry_id,
            minutes: &1.play_minutes - &1.remaining
          }
        )
        |> Enum.filter(&(&1.minutes > 0.0))

      Mix.shell().info(
        "#{length(to_backfill)} of #{length(replayed)} entries have consumption to backfill."
      )

      if dry_run? do
        Enum.each(to_backfill, fn row ->
          Mix.shell().info(
            "  (dry run) activity=#{row.activity_id} entry=#{inspect(row.time_entry_id)}: " <>
              "#{Float.round(row.minutes, 1)}"
          )
        end)
      else
        # One atomic batch, not a write per entry: this task refuses to run
        # against a User who already has rows, so a partial write could
        # neither be completed nor safely re-run — and a half-seeded ledger
        # reports a permanently wrong deficit (ADR-0012).
        case @persistence.record_entry_consumptions(user.id, to_backfill) do
          {:ok, count} ->
            Mix.shell().info("Backfilled #{count} entries for User #{user.id}.")

          {:error, reason} ->
            Mix.raise("backfill failed, nothing was written: #{inspect(reason)}")
        end
      end
    else
      # Without this, an {:error, _} from any lookup above would fall
      # straight out of run/1 with nothing printed — an operator would see a
      # clean exit and reasonably conclude the ledger had been seeded.
      {:error, reason} ->
        Mix.raise("could not read this User's history: #{inspect(reason)}")
    end
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
    integration = Accounts.get_integration(user)
    module = TimeSource.for(integration)

    case integration do
      nil ->
        {module, []}

      integration ->
        case module.connect(integration.credentials) do
          {:ok, client} ->
            {module, [client: client]}

          {:error, reason} ->
            Mix.shell().info("(no connection: #{inspect(reason)} — entries will be empty)")
            {module, []}
        end
    end
  end
end
