defmodule TimingPlayTimeWeb.SettingsLive do
  use TimingPlayTimeWeb, :live_view

  alias TimingPlayTime.Accounts

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:page_title, "Settings")
      |> assign(:integration, Accounts.get_integration(socket.assigns.current_user))

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
  def handle_event("save_integration", %{"api_key" => api_key}, socket) do
    attrs = %{provider: "timing", credentials: %{"api_key" => api_key}}

    case Accounts.upsert_integration(socket.assigns.current_user, attrs) do
      {:ok, integration} ->
        socket =
          socket
          |> assign(:integration, integration)
          |> put_flash(:info, "Timing integration saved.")

        {:noreply, socket}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Please enter an API key.")}
    end
  end
end
