defmodule TimingPlayTimeWeb.SourcePickerComponent do
  @moduledoc """
  The hierarchical Source picker for the Add/Edit Activity forms (ADR-0014).

  A `LiveComponent`, not a plain function component: it owns filtering and
  dropdown state, and it can't wrap its input in a `<form phx-change>` (it
  already sits *inside* the Activity `<form phx-submit>`, and forms can't
  nest), so filtering is driven by `phx-keyup` with `phx-target={@myself}`.

  It renders, inside the parent form:

    * `<input name="time_source_identifier">` - the picked Source's bare id
      (a hidden field in picker mode; the visible text field in manual mode)
    * `<input type="hidden" name="time_source_label">` - the flattened path
      label snapshot (`"Edu → Coding"`), blank in manual mode

  ## Attributes

    * `:id` (required) - LiveComponent id; distinct per embed
      (`"source-picker-new"`, `"source-picker-<activity id>"`)
    * `:source_list` (required) - the async fetch state from the parent:
      `:loading`, `:no_integration`, `{:ok, [TimeSource.source()]}`, or
      `:error`
    * `:current_id` - the Activity's stored `time_source_identifier` (Edit
      only); preselects the matching row, or opens manual mode showing it
    * `:current_label` - the Activity's stored `time_source_label` (Edit only)

  Keyboard navigation of the dropdown is intentionally not implemented — it's
  a SHOULD in the spec, and skipping it keeps this a pure-LiveView component
  with no JS hook (a keyboard select would need one to rewrite the focused
  input's value).
  """
  use TimingPlayTimeWeb, :live_component

  @impl true
  def update(assigns, socket) do
    source_list = assigns.source_list
    changed? = socket.assigns[:source_list] != source_list

    socket =
      socket
      |> assign(:id, assigns.id)
      |> assign(:source_list, source_list)
      |> assign(:current_id, assigns[:current_id])
      |> assign(:current_label, assigns[:current_label])
      |> assign_new(:query, fn -> "" end)
      |> assign_new(:open, fn -> false end)
      |> assign_new(:selected_id, fn -> nil end)
      |> assign_new(:selected_label, fn -> nil end)
      |> assign_new(:manual_value, fn -> "" end)
      |> assign_new(:mode, fn -> :manual end)
      |> assign_new(:load_state, fn -> :loading end)
      |> assign_new(:sources, fn -> [] end)
      |> assign_new(:results, fn -> [] end)

    # `results` only needs recomputing when the source list itself changes;
    # the filter/pick events keep it current otherwise, so an unrelated
    # parent re-render (the 60s dashboard refresh, a multiplier +/- click)
    # doesn't re-scan the whole list.
    socket =
      if changed? do
        socket = init_from_source_list(socket, source_list, assigns[:current_id], assigns[:current_label])
        assign(socket, :results, filter(socket.assigns.sources, socket.assigns.query))
      else
        socket
      end

    {:ok, socket}
  end

  # Seeds mode / load_state / any Edit preselection the first time a given
  # `source_list` value arrives (loading -> ready happens once, as the async
  # fetch resolves).
  defp init_from_source_list(socket, :loading, current_id, _current_label) do
    if is_binary(current_id) and current_id != "" do
      # Edit form, list still in flight: show the stored id in manual mode so
      # a save before the list resolves can't submit a blank
      # `time_source_identifier`. Re-inits to a preselected picker once ready.
      assign(socket, load_state: :loading, mode: :manual, sources: [], manual_value: current_id)
    else
      assign(socket, load_state: :loading, mode: :picker, sources: [])
    end
  end

  defp init_from_source_list(socket, unavailable, current_id, _current_label)
       when unavailable in [:error, :no_integration] do
    state = if unavailable == :error, do: :error, else: :no_integration

    assign(socket,
      load_state: state,
      mode: :manual,
      sources: [],
      manual_value: current_id || "",
      open: false
    )
  end

  defp init_from_source_list(socket, {:ok, []}, current_id, _current_label) do
    assign(socket,
      load_state: :empty,
      mode: :manual,
      sources: [],
      manual_value: current_id || "",
      open: false
    )
  end

  defp init_from_source_list(socket, {:ok, sources}, current_id, current_label) do
    socket = assign(socket, load_state: :ready, sources: sources, open: false)

    case Enum.find(sources, &(&1.id == current_id)) do
      nil when is_binary(current_id) and current_id != "" ->
        # Stored id no longer maps to a live Source — keep it, in manual mode.
        assign(socket, mode: :manual, manual_value: current_id)

      nil ->
        assign(socket, mode: :picker, selected_id: nil, selected_label: nil, query: "")

      source ->
        label = current_label || path_string(source)
        assign(socket, mode: :picker, selected_id: source.id, selected_label: label, query: label)
    end
  end

  @impl true
  def handle_event("open_dropdown", _params, socket) do
    {:noreply, assign(socket, :open, socket.assigns.load_state == :ready)}
  end

  def handle_event("close_dropdown", _params, socket) do
    {:noreply, assign(socket, :open, false)}
  end

  def handle_event("filter", %{"key" => "Escape"}, socket) do
    {:noreply, assign(socket, :open, false)}
  end

  def handle_event("filter", %{"value" => value}, socket) do
    {:noreply,
     socket
     |> assign(:query, value)
     |> assign(:open, socket.assigns.load_state == :ready)
     |> assign(:results, filter(socket.assigns.sources, value))}
  end

  def handle_event("manual_input", %{"value" => value}, socket) do
    {:noreply, assign(socket, :manual_value, value)}
  end

  def handle_event("pick", %{"id" => id}, socket) do
    case Enum.find(socket.assigns.sources, &(&1.id == id)) do
      nil ->
        # The list changed out from under the rendered row — ignore rather
        # than crash the LiveView.
        {:noreply, socket}

      source ->
        label = path_string(source)

        {:noreply,
         socket
         |> assign(selected_id: source.id, selected_label: label, query: label, open: false)
         |> assign(:results, filter(socket.assigns.sources, label))}
    end
  end

  def handle_event("to_manual", _params, socket) do
    {:noreply,
     assign(socket,
       mode: :manual,
       open: false,
       manual_value: socket.assigns.selected_id || socket.assigns.manual_value
     )}
  end

  def handle_event("to_picker", _params, socket) do
    {:noreply, assign(socket, :mode, :picker)}
  end

  # case-insensitive; whitespace-split tokens that must ALL appear somewhere
  # in the "<ancestors> <title>" path (AND, order-independent). One token is
  # a plain substring test. The "→" separator is neither in the haystack nor
  # a token — so the path string left in the field after a pick
  # ("Development → App") still matches its own row on the next focus.
  defp filter(sources, query) do
    tokens =
      query
      |> String.downcase()
      |> String.replace("→", " ")
      |> String.split(~r/\s+/, trim: true)

    Enum.filter(sources, fn source ->
      haystack = [source.title | source.ancestors] |> Enum.join(" ") |> String.downcase()
      Enum.all?(tokens, &String.contains?(haystack, &1))
    end)
  end

  defp path_string(%{ancestors: [], title: title}), do: title
  defp path_string(%{ancestors: ancestors, title: title}), do: Enum.join(ancestors ++ [title], " → ")

  # The hidden `time_source_label` value. In manual mode the stored snapshot
  # is preserved as long as the id wasn't retyped — ADR-0014: the label is a
  # pick-time snapshot, never auto-refreshed, and an edit that doesn't
  # re-pick the Source must not blank it.
  defp label_value(%{mode: :picker, selected_label: label}), do: label || ""

  defp label_value(%{manual_value: value, current_id: value, current_label: label})
       when is_binary(value),
       do: label || ""

  defp label_value(_assigns), do: ""

  @impl true
  def render(assigns) do
    ~H"""
    <div id={@id}>
      <div class="flex items-baseline justify-between mb-2">
        <label class="block text-sm font-semibold text-gray-700">Source</label>
        <button
          :if={@load_state == :ready}
          type="button"
          phx-click={if @mode == :picker, do: "to_manual", else: "to_picker"}
          phx-target={@myself}
          class="text-xs font-medium text-purple-600 hover:text-purple-800 underline"
        >
          {if @mode == :picker, do: "enter ID manually", else: "back to picker"}
        </button>
      </div>

      <input type="hidden" name="time_source_label" value={label_value(assigns)} />

      <div :if={@mode == :manual}>
        <input
          type="text"
          name="time_source_identifier"
          value={@manual_value}
          phx-keyup="manual_input"
          phx-target={@myself}
          autocomplete="off"
          placeholder="paste a Source ID"
          class="w-full px-4 py-3 rounded-xl border-2 border-pink-300 focus:border-pink-500 focus:ring focus:ring-pink-200 focus:ring-opacity-50 text-gray-900 placeholder-gray-400 bg-pink-50"
          required
        />
        <p :if={@load_state in [:error, :empty]} class="mt-1 text-xs text-amber-600">
          {if @load_state == :error,
            do: "Couldn't load Sources — enter the ID by hand.",
            else: "No Sources found for this integration — enter the ID by hand."}
        </p>
      </div>

      <div :if={@mode == :picker} phx-click-away="close_dropdown" phx-target={@myself} class="relative">
        <input
          type="text"
          value={@query}
          disabled={@load_state == :loading}
          phx-focus="open_dropdown"
          phx-keyup="filter"
          phx-target={@myself}
          autocomplete="off"
          placeholder={if @load_state == :loading, do: "loading Sources…", else: "Search Sources…"}
          class="w-full px-4 py-3 rounded-xl border-2 border-pink-300 focus:border-pink-500 focus:ring focus:ring-pink-200 focus:ring-opacity-50 text-gray-900 placeholder-gray-400 bg-pink-50 disabled:opacity-60"
        />
        <input type="hidden" name="time_source_identifier" value={@selected_id || ""} />

        <div
          :if={@open and @load_state == :ready}
          class="absolute z-10 mt-1 w-full max-h-72 overflow-auto rounded-xl border-2 border-pink-200 bg-white shadow-xl"
        >
          <div :if={@results == []} class="px-4 py-3 text-sm text-gray-500">
            No match —
            <button
              type="button"
              phx-click="to_manual"
              phx-target={@myself}
              class="text-purple-600 underline"
            >
              enter ID manually
            </button>.
          </div>
          <button
            :for={source <- @results}
            type="button"
            phx-click="pick"
            phx-value-id={source.id}
            phx-target={@myself}
            class="block w-full text-left px-4 py-2 text-sm hover:bg-pink-50"
          >
            <span :if={source.ancestors != []} class="text-gray-400">
              {Enum.join(source.ancestors, " → ")} →
            </span>
            <span class="font-semibold text-gray-900">{source.title}</span>
          </button>
        </div>
      </div>
    </div>
    """
  end
end
