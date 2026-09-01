defmodule TimingPlayTimeWeb.ProtoSourcePickerLive do
  @moduledoc """
  THROWAWAY PROTOTYPE for wayfinder ticket #28 (map #26).

  Exercises the hierarchical source-picker interaction that will replace the
  free-text "Timing Project" field in the Add/Edit Activity forms. Not wired to
  any real data or contract — the source list is a fixture that mirrors the
  shape of the user's real Timing account (mostly flat, a few 2-level nests).

  Route (dev only): /dev/proto/source-picker

  Questions this is here to answer:
    1. Does the flattened "A → B" path read cleanly, or is indentation needed even in v1?
    2. Focus / blur / escape behaviour — when does the dropdown open and close?
    3. Where does the manual-mode toggle live so it is discoverable but not noisy?
    4. Is arrow-key / Enter nav worth specifying as required, or is it polish?

  Delete this module, its template-free render, and the /dev route once #28 is resolved.
  """
  use TimingPlayTimeWeb, :live_view

  # --- fixture data -------------------------------------------------------------
  # Already in the shape the contract's `list_sources/1` will return:
  # %{id, title, ancestors, depth}, flattened pre-order DFS, al:pha within a level.
  @sources [
    %{id: "p-brainrot", title: "Brain Rot", ancestors: [], depth: 0},
    %{id: "p-youtube", title: "YouTube - excl educational", ancestors: ["Brain Rot"], depth: 1},
    %{id: "p-edu", title: "Edu", ancestors: [], depth: 0},
    %{id: "p-coding", title: "Coding", ancestors: ["Edu"], depth: 1},
    %{id: "p-schs", title: "SCHS", ancestors: [], depth: 0},
    %{id: "p-schs-dev", title: "Dev", ancestors: ["SCHS"], depth: 1},
    %{id: "p-schs-meet", title: "Meetings", ancestors: ["SCHS"], depth: 1},
    %{id: "p-admin", title: "Admin", ancestors: [], depth: 0},
    %{id: "p-errands", title: "Errands", ancestors: [], depth: 0},
    %{id: "p-exercise", title: "Exercise", ancestors: [], depth: 0},
    %{id: "p-reading", title: "Reading", ancestors: [], depth: 0},
    %{id: "p-writing", title: "Writing", ancestors: [], depth: 0}
  ]

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(
       load_state: :ready,
       mode: :picker,
       display: :path,
       arrow_nav: true,
       query: "",
       open: false,
       highlight: 0,
       selected_id: nil,
       selected_label: nil,
       manual_value: ""
     )
     |> recompute_results()}
  end

  # --- state simulator (prototype-only chrome) --------------------------------
  @impl true
  def handle_event("sim", %{"state" => state}, socket) do
    ls = String.to_existing_atom(state)

    # unavailable -> forced into manual; available -> back to the picker
    mode = if ls in [:error, :empty], do: :manual, else: :picker

    {:noreply, assign(socket, load_state: ls, open: false, mode: mode)}
  end

  def handle_event("display", %{"display" => d}, socket),
    do: {:noreply, assign(socket, display: String.to_existing_atom(d))}

  def handle_event("toggle_arrow_nav", _p, socket),
    do: {:noreply, assign(socket, arrow_nav: !socket.assigns.arrow_nav)}

  def handle_event("reset", _p, socket),
    do: {:noreply, assign(socket, selected_id: nil, selected_label: nil, query: "", manual_value: "") |> recompute_results()}

  # --- the actual picker interaction ----------------------------------------
  def handle_event("to_manual", _p, socket),
    do: {:noreply, assign(socket, mode: :manual, open: false)}

  def handle_event("to_picker", _p, socket),
    do: {:noreply, assign(socket, mode: :picker)}

  def handle_event("open_dropdown", _p, %{assigns: %{load_state: :ready}} = socket),
    do: {:noreply, assign(socket, open: true, highlight: 0)}

  def handle_event("open_dropdown", _p, socket), do: {:noreply, socket}

  def handle_event("close_dropdown", _p, socket),
    do: {:noreply, assign(socket, open: false)}

  def handle_event("manual_input", %{"value" => v}, socket),
    do: {:noreply, assign(socket, manual_value: v)}

  def handle_event("pick", %{"id" => id}, socket) do
    src = Enum.find(@sources, &(&1.id == id))
    {:noreply, assign(socket, selected_id: id, selected_label: path_string(src), query: path_string(src), open: false)}
  end

  # One keyup handler drives both filtering and keyboard nav, so the input
  # needs no <form> wrapper — it can sit directly inside the outer Activity form.
  def handle_event("picker_key", %{"key" => key} = params, socket) do
    value = Map.get(params, "value", socket.assigns.query)
    results = socket.assigns.results
    hi = socket.assigns.highlight
    nav? = socket.assigns.arrow_nav

    cond do
      key == "Escape" ->
        {:noreply, assign(socket, open: false)}

      nav? and key == "ArrowDown" ->
        {:noreply, assign(socket, open: true, highlight: min(hi + 1, max(length(results) - 1, 0)))}

      nav? and key == "ArrowUp" ->
        {:noreply, assign(socket, highlight: max(hi - 1, 0))}

      nav? and key == "Enter" and socket.assigns.open and results != [] ->
        src = Enum.at(results, hi)

        {:noreply,
         assign(socket,
           selected_id: src.id,
           selected_label: path_string(src),
           query: path_string(src),
           open: false
         )}

      key in ~w(ArrowDown ArrowUp Enter Shift Meta Control Alt Tab) ->
        {:noreply, socket}

      true ->
        {:noreply, socket |> assign(query: value, open: true) |> recompute_results()}
    end
  end

  defp recompute_results(socket) do
    assign(socket, results: filter(@sources, socket.assigns.query), highlight: 0)
  end

  # single token -> plain substring; 2+ tokens -> all must appear (order-independent)
  defp filter(sources, query) do
    tokens = query |> String.downcase() |> String.split(~r/\s+/, trim: true)

    Enum.filter(sources, fn s ->
      hay = [s.title | s.ancestors] |> Enum.join(" ") |> String.downcase()
      Enum.all?(tokens, &String.contains?(hay, &1))
    end)
  end

  defp path_string(%{ancestors: [], title: t}), do: t
  defp path_string(%{ancestors: a, title: t}), do: Enum.join(a ++ [t], " → ")

  defp submitted_value(%{mode: :manual, manual_value: v}), do: v
  defp submitted_value(%{selected_id: id}), do: id || ""

  # --- render --------------------------------------------------------------
  @impl true
  def render(assigns) do
    ~H"""
    <style>
      /* Tailwind utilities this prototype uses that aren't in the app's
         pre-built app.css (throwaway — the real feature rebuilds CSS). */
      .max-h-72 { max-height: 18rem; }
      .overflow-auto { overflow: auto; }
      .underline { text-decoration: underline; }
      .text-left { text-align: left; }
      .bg-pink-100 { background-color: #fce7f3; }
      .text-amber-600 { color: #d97706; }
      .border-purple-600 { border-color: #9333ea; }
      .shadow-xl { box-shadow: 0 20px 25px -5px rgba(0,0,0,.1), 0 8px 10px -6px rgba(0,0,0,.1); }
      .max-w-3xl { max-width: 48rem; }
      .max-w-sm { max-width: 24rem; }
      .mx-auto { margin-left: auto; margin-right: auto; }
      .space-y-6 > * + * { margin-top: 1.5rem; }
      .space-y-3 > * + * { margin-top: .75rem; }
      .space-y-1 > * + * { margin-top: .25rem; }
      .hover\:bg-pink-50:hover { background-color: #fdf2f8; }
      input:disabled { opacity: .6; }
    </style>
    <div class="max-w-3xl mx-auto p-8 space-y-6">
      <div>
        <h1 class="text-2xl font-bold text-gray-900">Source picker — prototype</h1>
        <p class="text-sm text-gray-500">
          wayfinder #28. Throwaway. Fixture data mirrors the real Timing account shape.
        </p>
      </div>

      <%!-- prototype control chrome (not part of the real feature) --%>
      <div class="rounded-xl border border-gray-200 bg-gray-50 p-4 text-sm space-y-3">
        <div class="flex flex-wrap items-center gap-2">
          <span class="font-semibold text-gray-600">Source list state:</span>
          <button :for={s <- ~w(ready loading error empty)} phx-click="sim" phx-value-state={s}
            class={["px-2 py-1 rounded border", @load_state == String.to_existing_atom(s) && "bg-purple-600 text-white border-purple-600" || "bg-white border-gray-300"]}>
            {s}
          </button>
        </div>
        <div class="flex flex-wrap items-center gap-2">
          <span class="font-semibold text-gray-600">Row display:</span>
          <button :for={d <- ~w(path indented)} phx-click="display" phx-value-display={d}
            class={["px-2 py-1 rounded border", @display == String.to_existing_atom(d) && "bg-purple-600 text-white border-purple-600" || "bg-white border-gray-300"]}>
            {d}
          </button>
          <label class="ml-4 flex items-center gap-1">
            <input type="checkbox" checked={@arrow_nav} phx-click="toggle_arrow_nav" /> arrow-key nav
          </label>
          <button phx-click="reset" class="ml-auto px-2 py-1 rounded border bg-white border-gray-300">reset</button>
        </div>
      </div>

      <%!-- the field, as it would sit in the Add Activity form --%>
      <div class="bg-white rounded-2xl p-6 shadow-lg border-2 border-pink-200">
        <div class="max-w-sm">
          <div class="flex items-baseline justify-between mb-2">
            <label class="block text-sm font-semibold text-gray-700">Source</label>
            <button
              :if={@load_state == :ready}
              type="button"
              phx-click={if @mode == :picker, do: "to_manual", else: "to_picker"}
              class="text-xs font-medium text-purple-600 hover:text-purple-800 underline"
            >
              {if @mode == :picker, do: "enter ID manually", else: "back to picker"}
            </button>
          </div>

          <%= if @mode == :manual do %>
            <input
              type="text"
              name="time_source_identifier"
              value={@manual_value}
              phx-keyup="manual_input"
              placeholder="paste a source ID"
              class="w-full px-4 py-3 rounded-xl border-2 border-pink-300 focus:border-pink-500 bg-pink-50 text-gray-900"
            />
            <p :if={@load_state in [:error, :empty]} class="mt-1 text-xs text-amber-600">
              {if @load_state == :error, do: "Couldn't load sources — enter the ID by hand.", else: "No sources found for this integration — enter the ID by hand."}
            </p>
          <% else %>
            <div phx-click-away="close_dropdown" class="relative">
              <input
                type="text"
                autocomplete="off"
                value={@query}
                disabled={@load_state == :loading}
                phx-focus="open_dropdown"
                phx-keyup="picker_key"
                placeholder={if @load_state == :loading, do: "loading sources…", else: "Search projects…"}
                class="w-full px-4 py-3 rounded-xl border-2 border-pink-300 focus:border-pink-500 bg-pink-50 text-gray-900 disabled:opacity-60"
              />
              <input type="hidden" name="time_source_identifier" value={@selected_id || ""} />

              <div :if={@open and @load_state == :ready}
                class="absolute z-10 mt-1 w-full max-h-72 overflow-auto rounded-xl border-2 border-pink-200 bg-white shadow-xl">
                <%= if @results == [] do %>
                  <div class="px-4 py-3 text-sm text-gray-500">
                    No match.
                    <button type="button" phx-click="to_manual" class="text-purple-600 underline">Enter ID manually</button>.
                  </div>
                <% else %>
                  <button
                    :for={{s, i} <- Enum.with_index(@results)}
                    type="button"
                    phx-click="pick"
                    phx-value-id={s.id}
                    class={["w-full text-left px-4 py-2 text-sm hover:bg-pink-50",
                            i == @highlight && "bg-pink-100" || "bg-white"]}
                  >
                    <%= if @display == :indented do %>
                      <span style={"padding-left: #{s.depth}rem"} class={s.depth == 0 && "font-semibold text-gray-900" || "text-gray-700"}>
                        {s.title}
                      </span>
                    <% else %>
                      <span :if={s.ancestors != []} class="text-gray-400">{Enum.join(s.ancestors, " → ")} → </span>
                      <span class="font-semibold text-gray-900">{s.title}</span>
                    <% end %>
                  </button>
                <% end %>
              </div>
            </div>
          <% end %>
        </div>
      </div>

      <%!-- what the form would submit / internal state --%>
      <div class="rounded-xl border border-gray-200 bg-white p-4 text-sm font-mono space-y-1">
        <div><span class="text-gray-400">mode</span> = {@mode}</div>
        <div><span class="text-gray-400">query</span> = {inspect(@query)}</div>
        <div><span class="text-gray-400">tokens</span> = {inspect(String.split(String.downcase(@query), ~r/\s+/, trim: true))}</div>
        <div><span class="text-gray-400">matches</span> = {length(@results)}</div>
        <div><span class="text-gray-400">selected_id</span> = {inspect(@selected_id)}</div>
        <div><span class="text-gray-400">selected_label</span> = {inspect(@selected_label)}</div>
        <div class="pt-1 border-t border-gray-100">
          <span class="text-gray-400">time_source_identifier</span> =
          <span class="text-pink-700 font-bold">{inspect(submitted_value(assigns))}</span>
        </div>
      </div>
    </div>
    """
  end
end
