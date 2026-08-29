defmodule TimingPlayTimeWeb.EffectColors do
  @moduledoc """
  The single web-side definition of the fixed 4-band Effect ramp (#11):
  teal for an earner, red for a drain, rung picked by `PlayBalance.band/1`.

  The drain run is `red-400 / 500 / 700 / 800` — it skips `red-600` on
  purpose: the even `400/500/600/700` run fails #11's adjacent-lightness
  gate for CVD. Do not "regularise" it.

  Class strings are spelled out in full (not composed at runtime) so
  Tailwind's source scanner keeps them.
  """

  @type effect :: :positive | :negative
  @type band :: TimingPlayTime.PlayBalance.band()

  @doc "Background fill for a chart segment or a legend swatch."
  @spec segment_class(effect(), band()) :: String.t()
  def segment_class(:positive, 1), do: "bg-teal-500"
  def segment_class(:positive, 2), do: "bg-teal-600"
  def segment_class(:positive, 3), do: "bg-teal-700"
  def segment_class(:positive, 4), do: "bg-teal-800"
  def segment_class(:negative, 1), do: "bg-red-400"
  def segment_class(:negative, 2), do: "bg-red-500"
  def segment_class(:negative, 3), do: "bg-red-700"
  def segment_class(:negative, 4), do: "bg-red-800"

  @doc """
  Left-rail border colour for an Activity card — side-specific
  (`border-l-*`) so the card's existing full border keeps its own colour
  and only the 4px rail carries the band signal.
  """
  @spec rail_class(effect(), band()) :: String.t()
  def rail_class(:positive, 1), do: "border-l-teal-500"
  def rail_class(:positive, 2), do: "border-l-teal-600"
  def rail_class(:positive, 3), do: "border-l-teal-700"
  def rail_class(:positive, 4), do: "border-l-teal-800"
  def rail_class(:negative, 1), do: "border-l-red-400"
  def rail_class(:negative, 2), do: "border-l-red-500"
  def rail_class(:negative, 3), do: "border-l-red-700"
  def rail_class(:negative, 4), do: "border-l-red-800"

  @doc "Background fill for the signed multiplier chip (white text set in markup)."
  @spec chip_class(effect(), band()) :: String.t()
  def chip_class(effect, band), do: segment_class(effect, band)
end
