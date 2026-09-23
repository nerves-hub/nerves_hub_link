# SPDX-FileCopyrightText: 2026 Josh Kalderimis
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule NervesHubLink.AlarmsTest do
  use ExUnit.Case, async: true

  alias NervesHubLink.Alarms

  doctest NervesHubLink.Alarms

  describe "to_utc/2" do
    # Against the wall clock now, not as it was: an alarm set while the wall
    # clock still said 1970 comes out right once the clock has synced.
    test "dates a time by how long ago it was, against the wall clock now" do
      now = System.monotonic_time()
      earlier = now - System.convert_time_unit(90, :second, :native)

      assert Alarms.to_utc(earlier, {now, ~U[2026-09-24 12:00:00.000000Z]}) ==
               ~U[2026-09-24 11:58:30.000000Z]
    end

    test "defaults to now" do
      assert DateTime.diff(DateTime.utc_now(), Alarms.to_utc(System.monotonic_time()), :second) in 0..1
    end
  end

  describe "name/1" do
    test "is what health has always sent" do
      assert Alarms.name(MyApp.HighTemp) == "MyApp.HighTemp"
      assert Alarms.name({:disk_almost_full, ~c"/data"}) == ~s|{:disk_almost_full, ~c"/data"}|
    end
  end

  describe "reportable?/1" do
    test "leaves out the root filesystem's disk alarm by default" do
      refute Alarms.reportable?({:disk_almost_full, ~c"/"})
      assert Alarms.reportable?({:disk_almost_full, ~c"/data"})
      assert Alarms.reportable?(MyApp.HighTemp)
    end
  end
end
