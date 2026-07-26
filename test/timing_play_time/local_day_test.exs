defmodule TimingPlayTime.LocalDayTest do
  use ExUnit.Case, async: true

  alias TimingPlayTime.LocalDay

  describe "start_of_today/2" do
    test "returns the UTC instant of local midnight, in NZ standard time (winter, UTC+12)" do
      # 2026-07-25T10:00:00Z is 2026-07-25T22:00:00+12:00 in Pacific/Auckland (NZST, no DST in July).
      now = ~U[2026-07-25 10:00:00Z]

      assert LocalDay.start_of_today("Pacific/Auckland", now) == ~U[2026-07-24 12:00:00Z]
    end

    test "returns the UTC instant of local midnight, in NZ daylight time (summer, UTC+13)" do
      # 2026-01-15T05:00:00Z is 2026-01-15T18:00:00+13:00 in Pacific/Auckland (NZDT, daylight saving).
      now = ~U[2026-01-15 05:00:00Z]

      assert LocalDay.start_of_today("Pacific/Auckland", now) == ~U[2026-01-14 11:00:00Z]
    end
  end
end
