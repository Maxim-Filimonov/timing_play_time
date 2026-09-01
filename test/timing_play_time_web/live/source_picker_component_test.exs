defmodule TimingPlayTimeWeb.SourcePickerComponentTest do
  use TimingPlayTimeWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias TimingPlayTimeWeb.SourcePickerComponent

  @sources [
    %{id: "edu", title: "Edu", ancestors: [], depth: 0},
    %{id: "coding", title: "Coding", ancestors: ["Edu"], depth: 1},
    %{id: "schs", title: "SCHS", ancestors: [], depth: 0},
    %{id: "dev", title: "Dev", ancestors: ["SCHS"], depth: 1}
  ]

  defp render_picker(assigns) do
    render_component(SourcePickerComponent, Map.merge(%{id: "sp", source_list: :loading}, assigns))
  end

  describe "load_state rendering" do
    test "loading: the search input is disabled with a loading placeholder" do
      html = render_picker(%{source_list: :loading})

      assert html =~ ~s(placeholder="loading Sources…")
      # the boolean `disabled` attribute, not just the `disabled:` CSS class
      assert html =~ ~r/<input[^>]*\sdisabled\s/
      refute html =~ "enter ID manually"
    end

    test "no integration: manual id entry, no dropdown, no toggle" do
      html = render_picker(%{source_list: :no_integration})

      assert html =~ ~s(name="time_source_identifier")
      assert html =~ ~s(placeholder="paste a Source ID")
      refute html =~ "enter ID manually"
      refute html =~ "Search Sources"
    end

    test "error: manual entry with a 'couldn't load' hint, toggle hidden" do
      html = render_picker(%{source_list: :error})

      assert html =~ "Couldn&#39;t load Sources"
      refute html =~ "enter ID manually"
    end

    test "empty list: manual entry with a 'no Sources found' hint, toggle hidden" do
      html = render_picker(%{source_list: {:ok, []}})

      assert html =~ "No Sources found for this integration"
      refute html =~ "enter ID manually"
    end

    test "ready: the picker is shown with a visible manual-mode toggle" do
      html = render_picker(%{source_list: {:ok, @sources}})

      assert html =~ ~s(placeholder="Search Sources…")
      assert html =~ "enter ID manually"
      # hidden field carries the (empty) picked id
      assert html =~ ~s(<input type="hidden" name="time_source_identifier" value="")
    end
  end

  describe "Edit preselection" do
    test "a stored id that matches a Source preselects it, showing the flattened path" do
      html =
        render_picker(%{source_list: {:ok, @sources}, current_id: "coding", current_label: nil})

      assert html =~ ~s(value="Edu → Coding")
      assert html =~ ~s(name="time_source_identifier" value="coding")
    end

    test "a stored label snapshot is preferred over the live path when preselecting" do
      html =
        render_picker(%{
          source_list: {:ok, @sources},
          current_id: "coding",
          current_label: "Edu → Coding (old name)"
        })

      assert html =~ ~s|value="Edu → Coding (old name)"|
    end

    test "a stored id that matches no Source opens in manual mode showing that id" do
      html =
        render_picker(%{source_list: {:ok, @sources}, current_id: "gone-upstream", current_label: nil})

      assert html =~ ~s(name="time_source_identifier")
      assert html =~ ~s(value="gone-upstream")
      assert html =~ ~s(placeholder="paste a Source ID")
    end
  end
end
