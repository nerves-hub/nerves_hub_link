# SPDX-FileCopyrightText: 2026 Josh Kalderimis
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule NervesHubLink.Extensions.HealthTest.StubReport do
  @moduledoc false
  @behaviour NervesHubLink.Extensions.Health.Report

  @impl NervesHubLink.Extensions.Health.Report
  def timestamp(), do: ~U[2026-01-01 00:00:00Z]

  @impl NervesHubLink.Extensions.Health.Report
  def metadata(), do: %{"placement" => "the shed"}

  @impl NervesHubLink.Extensions.Health.Report
  def alarms(), do: %{"SomeAlarm" => "[]"}

  @impl NervesHubLink.Extensions.Health.Report
  def metrics(), do: %{"cat_count" => 3}

  @impl NervesHubLink.Extensions.Health.Report
  def checks(), do: %{"cattery" => %{pass: true}}

  @impl NervesHubLink.Extensions.Health.Report
  def connectivity(), do: %{}
end

defmodule NervesHubLink.Extensions.HealthTest.BrokenReport do
  @moduledoc false
  @behaviour NervesHubLink.Extensions.Health.Report

  @impl NervesHubLink.Extensions.Health.Report
  def timestamp(), do: raise("the sensor is on fire")

  @impl NervesHubLink.Extensions.Health.Report
  def metadata(), do: %{}

  @impl NervesHubLink.Extensions.Health.Report
  def alarms(), do: %{}

  @impl NervesHubLink.Extensions.Health.Report
  def metrics(), do: %{}

  @impl NervesHubLink.Extensions.Health.Report
  def checks(), do: %{}

  @impl NervesHubLink.Extensions.Health.Report
  def connectivity(), do: %{}
end

defmodule NervesHubLink.Extensions.HealthTest.CatMetrics do
  @moduledoc false
  @behaviour NervesHubLink.Extensions.Health.MetricSet

  @impl NervesHubLink.Extensions.Health.MetricSet
  def sample(), do: %{cats_seen: 4, cats_fed: 2}
end

defmodule NervesHubLink.Extensions.HealthTest do
  use ExUnit.Case, async: false

  alias NervesHubLink.Alarms
  alias NervesHubLink.Extensions.Health
  alias NervesHubLink.Extensions.Health.DefaultReport
  alias NervesHubLink.Extensions.HealthTest.BrokenReport
  alias NervesHubLink.Extensions.HealthTest.CatMetrics
  alias NervesHubLink.Extensions.HealthTest.StubReport

  @check_failed NervesHubLink.Extensions.Health.CheckFailed

  setup do
    previous = Application.get_env(:nerves_hub_link, :health)

    on_exit(fn ->
      if previous do
        Application.put_env(:nerves_hub_link, :health, previous)
      else
        Application.delete_env(:nerves_hub_link, :health)
      end

      Alarms.clear_alarm(@check_failed)
    end)

    Alarms.clear_alarm(@check_failed)

    :ok
  end

  describe "check_health/1" do
    test "builds a device status from the report" do
      status = Health.check_health(StubReport)

      assert status.timestamp == ~U[2026-01-01 00:00:00Z]
      assert status.metadata == %{"placement" => "the shed"}
      assert status.alarms == %{"SomeAlarm" => "[]"}
      assert status.metrics == %{"cat_count" => 3}
      assert status.checks == %{"cattery" => %{pass: true}}
    end

    test "a configured report module is used instead of the default" do
      put_health_config(report: StubReport)

      assert Health.check_health(DefaultReport).metrics == %{"cat_count" => 3}
    end

    test "reporting can be turned off" do
      put_health_config(report: nil)

      assert Health.check_health(StubReport) == nil
    end

    test "a report that raises is turned into an alarm rather than crashing" do
      status = Health.check_health(BrokenReport)

      assert status.metrics == %{}
      assert [{_alarm, reason}] = Map.to_list(status.alarms)
      assert reason =~ "the sensor is on fire"

      assert alarm_eventually_set?(@check_failed)
    end
  end

  describe "DefaultReport metrics" do
    test "metric sets can be turned off" do
      put_health_config(metric_sets: [])

      assert DefaultReport.metrics() == %{}
    end

    test "a custom metric set is sampled and its keys normalized" do
      put_health_config(metric_sets: [CatMetrics])

      assert DefaultReport.metrics() == %{"cats_seen" => 4, "cats_fed" => 2}
    end

    test "the defaults can be combined with a custom metric set" do
      # Which metrics the default sets produce depends on the host, so compare
      # against the defaults on their own rather than naming any of them
      put_health_config(metric_sets: [:defaults])
      default_keys = DefaultReport.metrics() |> Map.keys() |> Enum.sort()

      put_health_config(metric_sets: [:defaults, CatMetrics])
      combined = DefaultReport.metrics()

      assert combined["cats_seen"] == 4
      assert combined["cats_fed"] == 2

      assert combined |> Map.drop(["cats_seen", "cats_fed"]) |> Map.keys() |> Enum.sort() ==
               default_keys
    end

    test "metrics can be given directly in the config" do
      put_health_config(metric_sets: [], metrics: %{"battery" => 87})

      assert DefaultReport.metrics() == %{"battery" => 87}
    end
  end

  describe "DefaultReport metadata and checks" do
    test "metadata is read from the config" do
      put_health_config(metadata: %{"placement" => "the shed"})

      assert DefaultReport.metadata() == %{"placement" => "the shed"}
    end

    test "metadata can be produced by an MFA" do
      put_health_config(metadata: %{"placement" => {String, :upcase, ["the shed"]}})

      assert DefaultReport.metadata() == %{"placement" => "THE SHED"}
    end

    test "checks are read from the config" do
      put_health_config(checks: %{"cattery" => %{pass: true}})

      assert DefaultReport.checks() == %{"cattery" => %{pass: true}}
    end
  end

  describe "DefaultReport alarms" do
    test "the root filesystem disk alarm is ignored by default" do
      set_disk_alarm("/")

      refute Map.has_key?(DefaultReport.alarms(), inspect({:disk_almost_full, ~c"/"}))
    end

    test "the ignored mounts can be configured" do
      put_health_config(alarms: [ignore_disk_full_mounts: ["/data"]])

      set_disk_alarm("/data")
      set_disk_alarm("/")

      alarms = DefaultReport.alarms()

      refute Map.has_key?(alarms, inspect({:disk_almost_full, ~c"/data"}))
      # Configuring the mounts replaces the default, so "/" is reported now
      assert Map.has_key?(alarms, inspect({:disk_almost_full, ~c"/"}))
    end

    test "other alarms are reported" do
      Alarms.set_alarm({NervesHubLink.Disconnected, []})
      on_exit(fn -> Alarms.clear_alarm(NervesHubLink.Disconnected) end)

      assert wait_until(fn ->
               Map.has_key?(DefaultReport.alarms(), inspect(NervesHubLink.Disconnected))
             end)
    end
  end

  defp put_health_config(config) do
    Application.put_env(:nerves_hub_link, :health, config)
  end

  defp set_disk_alarm(mount) do
    alarm_id = {:disk_almost_full, to_charlist(mount)}

    Alarms.set_alarm({alarm_id, []})
    on_exit(fn -> Alarms.clear_alarm(alarm_id) end)

    assert alarm_eventually_set?(alarm_id)
  end

  defp alarm_eventually_set?(alarm_id) do
    wait_until(fn -> Enum.any?(Alarms.get_alarms(), &(elem(&1, 0) == alarm_id)) end)
  end

  defp wait_until(fun, timeout \\ 500)
  defp wait_until(fun, timeout) when timeout <= 0, do: fun.()

  defp wait_until(fun, timeout) do
    if fun.() do
      true
    else
      Process.sleep(10)
      wait_until(fun, timeout - 10)
    end
  end
end
