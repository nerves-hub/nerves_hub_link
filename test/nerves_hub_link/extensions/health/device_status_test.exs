# SPDX-FileCopyrightText: 2026 Josh Kalderimis
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule NervesHubLink.Extensions.Health.DeviceStatusTest do
  use ExUnit.Case, async: true

  alias NervesHubLink.Extensions.Health.DeviceStatus

  describe "new/1" do
    test "keeps what it is given" do
      status =
        DeviceStatus.new(
          timestamp: ~U[2026-08-12 01:02:03Z],
          metadata: %{"placement" => "the shed"},
          alarms: %{"SomeAlarm" => "[]"},
          metrics: %{"cpu_usage_percent" => 12.5},
          checks: %{"cattery" => %{pass: true}},
          connectivity: %{"eth0" => %{type: :ethernet}}
        )

      assert status.timestamp == ~U[2026-08-12 01:02:03Z]
      assert status.metadata == %{"placement" => "the shed"}
      assert status.alarms == %{"SomeAlarm" => "[]"}
      assert status.metrics == %{"cpu_usage_percent" => 12.5}
      assert status.checks == %{"cattery" => %{pass: true}}
      assert status.connectivity == %{"eth0" => %{type: :ethernet}}
    end

    test "fills in anything left out" do
      status = DeviceStatus.new([])

      assert %DateTime{} = status.timestamp
      assert status.metadata == %{}
      assert status.alarms == %{}
      assert status.metrics == %{}
      assert status.checks == %{}
      assert status.connectivity == %{}
    end

    test "a report that leaves out connectivity still gets an empty map" do
      # `check_health/1` builds a status without connectivity, so this is the
      # shape NervesHub actually receives
      status =
        DeviceStatus.new(
          timestamp: ~U[2026-08-12 01:02:03Z],
          metadata: %{},
          alarms: %{},
          metrics: %{},
          checks: %{}
        )

      assert status.connectivity == %{}
    end
  end

  describe "encoding" do
    test "encodes as JSON with an ISO 8601 timestamp" do
      status = DeviceStatus.new(timestamp: ~U[2026-08-12 01:02:03.456789Z])

      assert %{"timestamp" => timestamp} = status |> Jason.encode!() |> Jason.decode!()
      assert timestamp == "2026-08-12T01:02:03.456789Z"
    end

    test "encodes as msgpack with a native timestamp" do
      status = DeviceStatus.new(timestamp: ~U[2026-08-12 01:02:03.456789Z])

      assert %{"timestamp" => timestamp} = status |> Msgpax.pack!() |> Msgpax.unpack!()
      assert timestamp == ~U[2026-08-12 01:02:03.456789Z]
    end

    test "every field survives a msgpack round-trip" do
      status =
        DeviceStatus.new(
          timestamp: ~U[2026-08-12 01:02:03Z],
          metadata: %{"placement" => "the shed"},
          alarms: %{"SomeAlarm" => "[]"},
          metrics: %{"cpu_usage_percent" => 12.5},
          checks: %{"cattery" => %{"pass" => true}},
          connectivity: %{}
        )

      decoded = status |> Msgpax.pack!() |> Msgpax.unpack!()

      assert decoded["metadata"] == %{"placement" => "the shed"}
      assert decoded["alarms"] == %{"SomeAlarm" => "[]"}
      assert decoded["metrics"] == %{"cpu_usage_percent" => 12.5}
      assert decoded["checks"] == %{"cattery" => %{"pass" => true}}
      assert decoded["connectivity"] == %{}
    end
  end
end
