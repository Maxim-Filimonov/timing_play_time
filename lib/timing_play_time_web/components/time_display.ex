defmodule TimingPlayTimeWeb.Components.TimeDisplay do
  @moduledoc """
  Formats and renders a minutes value, switching to hours once it reaches 60.
  """
  use Phoenix.Component

  def format_time(minutes, format \\ :long)

  def format_time(minutes, format) when minutes >= 60 do
    {Float.round(minutes / 60, 1), hours_unit(format)}
  end

  def format_time(minutes, format) do
    {Float.round(minutes, 1), minutes_unit(format)}
  end

  defp minutes_unit(:long), do: "minutes"
  defp minutes_unit(:short), do: "min"

  defp hours_unit(:long), do: "hours"
  defp hours_unit(:short), do: "hr"

  attr(:minutes, :float, required: true)
  attr(:format, :atom, values: [:long, :short], default: :long)
  attr(:value_class, :string, default: nil)
  attr(:unit_class, :string, default: nil)

  def time_display(assigns) do
    {value, unit} = format_time(assigns.minutes, assigns.format)
    assigns = assign(assigns, value: value, unit: unit)

    ~H"""
    <span class={@value_class}>{@value}</span>
    <span class={@unit_class}>{@unit}</span>
    """
  end
end
