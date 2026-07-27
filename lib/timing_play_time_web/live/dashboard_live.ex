defmodule TimingPlayTimeWeb.DashboardLive do
  use TimingPlayTimeWeb, :live_view

  alias TimingPlayTime.PlayBalance
  alias TimingPlayTime.ActivityManager
  alias TimingPlayTime.ManualSync
  alias TimingPlayTime.PlaytimeUsed
  alias TimingPlayTime.Accounts

  @time_source Application.compile_env!(:timing_play_time, :time_source_adapter)

  # Keeps the dashboard live-updating while the tab is open, without a
  # background job queue (ADR-0007) — data goes stale again once the tab
  # closes, which is fine since nobody's looking at it then.
  @refresh_interval_ms :timer.seconds(60)

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_user

    socket =
      socket
      |> assign(:page_title, "Dashboard")
      |> assign(:client, nil)
      |> assign(:balance, nil)
      |> assign(:today, nil)
      |> assign(:show_debug, false)
      |> assign(:activities, nil)
      |> assign(:editing_activity_id, nil)
      |> assign(:editing_multiplier, nil)

    # The static (disconnected) render has no client to query Timing with, so
    # `get_elapsed_minutes` would fail and silently score every Activity as 0
    # (per compute_timing_derived_total's "skip failed activities" behaviour)
    # — showing a spurious, often-negative balance that then jumps to the
    # real number once the socket connects. Deferring all of this to the
    # connected mount avoids that flash and shows a loading state instead.
    socket =
      if connected?(socket) do
        Phoenix.PubSub.subscribe(TimingPlayTime.PubSub, balance_topic(user))
        Process.send_after(self(), :refresh, @refresh_interval_ms)

        socket
        |> open_time_source_connection()
        |> load_balance()
        |> load_activities()
      else
        socket
      end

    {:ok, socket}
  end

  @impl true
  def handle_event("detected_timezone", %{"timezone" => timezone}, socket) do
    socket =
      if socket.assigns.current_user.timezone do
        socket
      else
        case Accounts.update_timezone(socket.assigns.current_user, timezone) do
          {:ok, user} -> socket |> assign(:current_user, user) |> load_activities()
          {:error, _changeset} -> socket
        end
      end

    {:noreply, socket}
  end

  @impl true
  def handle_event("log_playtime", %{"minutes" => minutes_str}, socket) do
    case Float.parse(minutes_str) do
      {minutes, _} when minutes > 0 ->
        {:ok, _usage} = PlaytimeUsed.log_usage(socket.assigns.current_user.id, minutes)

        broadcast_balance_updated(socket.assigns.current_user)

        socket =
          socket
          |> load_balance()
          |> put_flash(:info, "Logged #{minutes} play minutes!")

        {:noreply, socket}

      _ ->
        {:noreply, put_flash(socket, :error, "Please enter a valid number")}
    end
  end

  @impl true
  def handle_event("set_manual_sync", %{"minutes" => minutes_str}, socket) do
    case Float.parse(minutes_str) do
      {minutes, _} when minutes >= 0 ->
        {:ok, _total} = ManualSync.set_total(socket.assigns.current_user.id, minutes)

        broadcast_balance_updated(socket.assigns.current_user)

        socket =
          socket
          |> load_balance()
          |> put_flash(:info, "Exercise minutes set to #{minutes} minutes!")

        {:noreply, socket}

      _ ->
        {:noreply, put_flash(socket, :error, "Please enter a valid number")}
    end
  end

  @impl true
  def handle_event("reveal_debug", _params, socket) do
    {:noreply, assign(socket, :show_debug, true)}
  end

  @impl true
  def handle_event("hide_debug", _params, socket) do
    {:noreply, assign(socket, :show_debug, false)}
  end

  @multiplier_step 0.1

  @impl true
  def handle_event("edit_activity", %{"id" => id}, socket) do
    activity = Enum.find(socket.assigns.activities, &(&1.id == id))

    socket =
      socket
      |> assign(:editing_activity_id, id)
      |> assign(:editing_multiplier, activity.multiplier)

    {:noreply, socket}
  end

  @impl true
  def handle_event("cancel_edit_activity", _params, socket) do
    socket =
      socket
      |> assign(:editing_activity_id, nil)
      |> assign(:editing_multiplier, nil)

    {:noreply, socket}
  end

  @impl true
  def handle_event("increment_multiplier", _params, socket) do
    {:noreply, update(socket, :editing_multiplier, &step_multiplier(&1, @multiplier_step))}
  end

  @impl true
  def handle_event("decrement_multiplier", _params, socket) do
    {:noreply, update(socket, :editing_multiplier, &step_multiplier(&1, -@multiplier_step))}
  end

  @impl true
  def handle_event(
        "save_activity",
        %{"activity_id" => id, "name" => name, "time_source_identifier" => time_source_identifier},
        socket
      ) do
    attrs = %{
      name: name,
      time_source_identifier: time_source_identifier,
      multiplier: socket.assigns.editing_multiplier
    }

    socket =
      case ActivityManager.update_activity(socket.assigns.current_user.id, id, attrs) do
        {:ok, _activity} ->
          socket
          |> assign(:editing_activity_id, nil)
          |> assign(:editing_multiplier, nil)
          |> load_activities()
          |> put_flash(:info, "Updated activity #{name}!")

        {:error, _reason} ->
          put_flash(socket, :error, "Please fill in every field with valid values")
      end

    {:noreply, socket}
  end

  @impl true
  def handle_event(
        "create_activity",
        %{"name" => name, "time_source_identifier" => time_source_identifier, "multiplier" => multiplier_str},
        socket
      ) do
    with {multiplier, _} <- Float.parse(multiplier_str),
         {:ok, _activity} <-
           ActivityManager.create_activity(socket.assigns.current_user.id, %{
             name: name,
             time_source_identifier: time_source_identifier,
             multiplier: multiplier
           }) do
      socket =
        socket
        |> load_activities()
        |> put_flash(:info, "Added activity #{name}!")

      {:noreply, socket}
    else
      _ -> {:noreply, put_flash(socket, :error, "Please fill in every field with valid values")}
    end
  end

  @impl true
  def handle_info({:balance_updated, _payload}, socket) do
    {:noreply, load_balance(socket)}
  end

  @impl true
  def handle_info(:refresh, socket) do
    Process.send_after(self(), :refresh, @refresh_interval_ms)

    socket =
      socket
      |> load_balance()
      |> load_activities()

    {:noreply, socket}
  end

  # Rounded to 1 decimal place to avoid float drift from repeated +/- 0.1 steps
  # (e.g. 1.1 + 0.1 - 0.1 landing on 1.0999999999999999).
  defp step_multiplier(multiplier, delta) do
    (multiplier + delta) |> max(0.0) |> Float.round(1)
  end

  defp balance_topic(user), do: "play_balance:#{user.id}"

  defp broadcast_balance_updated(user) do
    Phoenix.PubSub.broadcast(TimingPlayTime.PubSub, balance_topic(user), {:balance_updated, %{}})
  end

  # Opens one connection for the lifetime of this LiveView process (ADR-0007)
  # — reused across every `@refresh_interval_ms` tick, torn down automatically
  # (it's linked to `self()`) when the LiveView terminates. Only meaningful
  # once connected (the initial static render has no business making an
  # external call), and only if the user has a configured Integration.
  defp open_time_source_connection(socket) do
    if connected?(socket) do
      case Accounts.get_integration(socket.assigns.current_user) do
        nil ->
          socket

        integration ->
          case @time_source.connect(integration.credentials) do
            {:ok, client} -> assign(socket, :client, client)
            {:error, _reason} -> socket
          end
      end
    else
      socket
    end
  end

  defp load_balance(socket) do
    user = socket.assigns.current_user
    time_source_opts = client_opts(socket)

    socket =
      case PlayBalance.compute(user, time_source_opts) do
        {:ok, balance} ->
          assign(socket, :balance, balance)

        {:error, _reason} ->
          assign(socket, :balance, %{
            total: 0.0,
            timing_derived_total: 0.0,
            manual_sync_total: 0.0,
            playtime_used_total: 0.0
          })
      end

    load_today(socket, user, time_source_opts)
  end

  @empty_today %{
    earned_today: 0.0,
    used_today: 0.0,
    exercise_minutes: 0.0,
    today_net: 0.0,
    playtime: 0.0
  }

  # Briefly nil on a brand-new anonymous user, until the `.TimezoneDetector`
  # hook's first pushEvent lands (ADR-0006) — LocalDay needs a real IANA
  # zone name, so this shows zero rather than crashing (mirrors
  # `with_today_minutes/2`'s same guard for the per-Activity figures).
  defp load_today(socket, %{timezone: nil}, _time_source_opts) do
    assign(socket, :today, @empty_today)
  end

  defp load_today(socket, user, time_source_opts) do
    case PlayBalance.compute_today(user, DateTime.utc_now(), time_source_opts) do
      {:ok, today} -> assign(socket, :today, today)
      {:error, _reason} -> assign(socket, :today, @empty_today)
    end
  end

  defp load_activities(socket) do
    user = socket.assigns.current_user

    case ActivityManager.list_activities(user.id) do
      {:ok, activities} ->
        assign(socket, :activities, Enum.map(activities, &with_today_minutes(&1, socket)))

      {:error, _reason} ->
        assign(socket, :activities, [])
    end
  end

  # Briefly nil on a brand-new anonymous user, until the `.TimezoneDetector`
  # hook's first pushEvent lands (ADR-0006) — shows zero rather than
  # crashing on a missing time zone.
  defp with_today_minutes(activity, %{assigns: %{current_user: %{timezone: nil}}}) do
    Map.merge(activity, %{minutes: 0.0, play_minutes: 0.0})
  end

  defp with_today_minutes(activity, socket) do
    user = socket.assigns.current_user
    time_source_opts = client_opts(socket)

    get_elapsed_minutes = fn a, opts -> @time_source.get_elapsed_minutes(a, opts ++ time_source_opts) end

    case PlayBalance.today_activity_minutes(activity, user, DateTime.utc_now(), get_elapsed_minutes) do
      {:ok, today} -> Map.merge(activity, today)
      {:error, _reason} -> Map.merge(activity, %{minutes: 0.0, play_minutes: 0.0})
    end
  end

  defp client_opts(socket) do
    case socket.assigns[:client] do
      nil -> []
      client -> [client: client]
    end
  end

  defp balance_percentage(%{total: total}) when total >= 200, do: 100
  defp balance_percentage(%{total: total}), do: min(100, round(total / 2))

  defp balance_gradient(%{total: total}) when total >= 100 do
    "bg-gradient-to-r from-green-400 to-emerald-500"
  end

  defp balance_gradient(%{total: total}) when total >= 50 do
    "bg-gradient-to-r from-orange-400 to-amber-500"
  end

  defp balance_gradient(_) do
    "bg-gradient-to-r from-red-400 to-rose-500"
  end
end
