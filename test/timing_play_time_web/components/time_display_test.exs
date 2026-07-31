defmodule TimingPlayTimeWeb.Components.TimeDisplayTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias TimingPlayTimeWeb.Components.TimeDisplay

  describe "format_time/2" do
    test "under 60 minutes, stays in minutes" do
      assert TimeDisplay.format_time(45.0) == {45.0, "minutes"}
    end

    test "at exactly 60 minutes, switches to hours" do
      assert TimeDisplay.format_time(60.0) == {1.0, "hours"}
    end

    test "over 60 minutes, converts to hours rounded to 1 decimal" do
      assert TimeDisplay.format_time(90.0) == {1.5, "hours"}
    end

    test "short format abbreviates minutes and hours" do
      assert TimeDisplay.format_time(45.0, :short) == {45.0, "min"}
      assert TimeDisplay.format_time(90.0, :short) == {1.5, "hr"}
    end
  end

  describe "time_display/1" do
    test "renders the value and unit for a sub-60-minute value" do
      html = render_component(&TimeDisplay.time_display/1, minutes: 45.0)

      assert html =~ "45.0"
      assert html =~ "minutes"
    end

    test "applies caller-supplied classes to the value and unit spans" do
      html =
        render_component(&TimeDisplay.time_display/1,
          minutes: 45.0,
          value_class: "text-7xl font-black",
          unit_class: "text-3xl text-purple-200"
        )

      assert html =~ ~s(class="text-7xl font-black")
      assert html =~ ~s(class="text-3xl text-purple-200")
    end

    test "renders the abbreviated unit when format is :short" do
      html = render_component(&TimeDisplay.time_display/1, minutes: 90.0, format: :short)

      assert html =~ "1.5"
      assert html =~ "hr"
      refute html =~ "hours"
    end
  end
end
