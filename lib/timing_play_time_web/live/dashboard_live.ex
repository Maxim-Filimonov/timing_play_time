defmodule TimingPlayTimeWeb.DashboardLive do
  use TimingPlayTimeWeb, :live_view

  alias TimingPlayTime.PlayBalance
  alias TimingPlayTime.ActivityManager
  alias TimingPlayTime.ManualSync
  alias TimingPlayTime.PlaytimeUsed

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(TimingPlayTime.PubSub, "play_balance")
    end

    socket =
      socket
      |> assign(:page_title, "Dashboard")
      |> load_balance()
      |> load_activities()

    {:ok, socket}
  end

  @impl true
  def handle_event("log_playtime", %{"minutes" => minutes_str}, socket) do
    case Float.parse(minutes_str) do
      {minutes, _} when minutes > 0 ->
        {:ok, _usage} = PlaytimeUsed.log_usage(minutes)

        Phoenix.PubSub.broadcast(
          TimingPlayTime.PubSub,
          "play_balance",
          {:balance_updated, %{}}
        )

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
        {:ok, _total} = ManualSync.set_total(minutes)

        Phoenix.PubSub.broadcast(
          TimingPlayTime.PubSub,
          "play_balance",
          {:balance_updated, %{}}
        )

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
  def handle_event(
        "create_activity",
        %{"name" => name, "time_source_identifier" => time_source_identifier, "multiplier" => multiplier_str},
        socket
      ) do
    with {multiplier, _} <- Float.parse(multiplier_str),
         {:ok, _activity} <-
           ActivityManager.create_activity(%{
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

  defp load_balance(socket) do
    case PlayBalance.compute() do
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
  end

  defp load_activities(socket) do
    case ActivityManager.list_activities() do
      {:ok, activities} ->
        assign(socket, :activities, Enum.map(activities, &with_today_minutes/1))

      {:error, _reason} ->
        assign(socket, :activities, [])
    end
  end

  defp with_today_minutes(activity) do
    case PlayBalance.today_activity_minutes(activity) do
      {:ok, today} -> Map.merge(activity, today)
      {:error, _reason} -> Map.merge(activity, %{minutes: 0.0, play_minutes: 0.0})
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
