defmodule TimingPlayTimeWeb.SettingsLive do
  use TimingPlayTimeWeb, :live_view

  alias TimingPlayTime.Accounts
  alias TimingPlayTime.ActivityManager

  @impl true
  def mount(_params, _session, socket) do
    activity_count = count_activities(socket.assigns.current_user.id)

    socket =
      socket
      |> assign(:page_title, "Settings")
      |> assign(:integration, Accounts.get_integration(socket.assigns.current_user))
      |> assign(:linked_email, socket.assigns.current_user.email)
      |> assign(:confirming_disconnect, false)
      |> assign(:activity_count, activity_count)

    {:ok, socket}
  end

  @impl true
  def handle_event("save_timezone", %{"timezone" => timezone}, socket) do
    case Accounts.update_timezone(socket.assigns.current_user, timezone) do
      {:ok, user} ->
        socket =
          socket
          |> assign(:current_user, user)
          |> put_flash(:info, "Timezone set to #{timezone}.")

        {:noreply, socket}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Please enter a valid timezone.")}
    end
  end

  @impl true
  def handle_event("save_integration_timing", %{"api_key" => api_key}, socket) do
    save_integration(socket, "timing", %{"api_key" => api_key}, "Timing integration saved.")
  end

  @impl true
  def handle_event("save_integration_rescuetime", %{"api_key" => api_key}, socket) do
    save_integration(socket, "rescuetime", %{"api_key" => api_key}, "RescueTime integration saved.")
  end

  # First click: with 0 Activities, disconnect immediately (nothing would
  # stop earning) — with 1+, show the inline warning instead of disconnecting
  # yet, requiring a second explicit click (ADR-0016).
  @impl true
  def handle_event("disconnect_integration", _params, socket) do
    count = count_activities(socket.assigns.current_user.id)
    socket = assign(socket, :activity_count, count)

    if count > 0 do
      {:noreply, assign(socket, :confirming_disconnect, true)}
    else
      {:noreply, do_disconnect(socket)}
    end
  end

  @impl true
  def handle_event("confirm_disconnect_integration", _params, socket) do
    {:noreply, do_disconnect(socket)}
  end

  @impl true
  def handle_event("cancel_disconnect_integration", _params, socket) do
    {:noreply, assign(socket, :confirming_disconnect, false)}
  end

  defp save_integration(socket, provider, credentials, success_message) do
    attrs = %{provider: provider, credentials: credentials}

    case Accounts.upsert_integration(socket.assigns.current_user, attrs) do
      {:ok, integration} ->
        socket =
          socket
          |> assign(:integration, integration)
          |> put_flash(:info, success_message)

        {:noreply, socket}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Please enter an API key.")}
    end
  end

  defp do_disconnect(socket) do
    {:ok, _integration} = Accounts.delete_integration(socket.assigns.current_user)

    socket
    |> assign(:integration, nil)
    |> assign(:confirming_disconnect, false)
    |> put_flash(:info, "Disconnected.")
  end

  # A count is only ever used to size a confirmation warning — a lookup
  # failure degrades to "nothing to warn about" (0) rather than crashing the
  # LiveView, the same swallow ActivityManager.list_activities/1 callers use
  # elsewhere (e.g. DashboardLive.fetch_activities_and_entries/1).
  defp count_activities(user_id) do
    case ActivityManager.count_activities(user_id) do
      {:ok, count} -> count
      {:error, _reason} -> 0
    end
  end

  defp integration_label(%{provider: "timing"}), do: "Timing"
  defp integration_label(%{provider: "rescuetime"}), do: "RescueTime"

  defp disconnect_warning(count) do
    activity_word = if count == 1, do: "Activity", else: "Activities"
    "Disconnecting will stop #{count} #{activity_word} from earning. Continue?"
  end
end
