defmodule TimingPlayTime.Plugins.TimeSourceTest do
  use ExUnit.Case, async: true

  alias TimingPlayTime.Accounts.Integration
  alias TimingPlayTime.Plugins.TimeSource
  alias TimingPlayTime.Plugins.TimeSource.RescueTime
  alias TimingPlayTime.Plugins.TimeSource.Timing

  # config/test.exs sets :time_source_adapter_override to the Stub, so these
  # override-bypassing assertions clear it for the duration of each test and
  # restore it afterwards — this module is what `for/1` looks like with the
  # override unset, i.e. what dev/prod actually see (ADR-0016).
  setup do
    override = Application.get_env(:timing_play_time, :time_source_adapter_override)
    Application.delete_env(:timing_play_time, :time_source_adapter_override)
    on_exit(fn -> Application.put_env(:timing_play_time, :time_source_adapter_override, override) end)
    :ok
  end

  test "resolves \"timing\" to the Timing adapter" do
    assert TimeSource.for(%Integration{provider: "timing"}) == Timing
  end

  test "resolves \"rescuetime\" to the RescueTime adapter" do
    assert TimeSource.for(%Integration{provider: "rescuetime"}) == RescueTime
  end

  test "raises for an unknown provider" do
    assert_raise KeyError, fn ->
      TimeSource.for(%Integration{provider: "some-other-app"})
    end
  end

  test "falls back to Timing for a User with no Integration yet" do
    assert TimeSource.for(nil) == Timing
  end
end
