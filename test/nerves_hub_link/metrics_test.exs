# SPDX-FileCopyrightText: 2026 Josh Kalderimis
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule NervesHubLink.MetricsTest.CatMetrics do
  @moduledoc false
  @behaviour NervesHubLink.MetricSet

  @impl NervesHubLink.MetricSet
  def sample(), do: %{cats_seen: 4, cats_fed: 2}
end

defmodule NervesHubLink.MetricsTest.Battery do
  @moduledoc false
  @spec percent() :: number()
  def percent(), do: 87
end

defmodule NervesHubLink.MetricsTest do
  use ExUnit.Case, async: false

  alias NervesHubLink.Metrics
  alias NervesHubLink.MetricSet
  alias NervesHubLink.MetricsTest.Battery
  alias NervesHubLink.MetricsTest.CatMetrics

  setup do
    previous_metrics = Application.get_env(:nerves_hub_link, :metrics)
    previous_health = Application.get_env(:nerves_hub_link, :health)

    on_exit(fn ->
      restore(:metrics, previous_metrics)
      restore(:health, previous_health)
    end)

    :ok
  end

  describe "metric_sets/0" do
    test "are the three default sets when nothing is configured" do
      assert Metrics.metric_sets() == [MetricSet.CPU, MetricSet.Disk, MetricSet.Memory]
    end

    test "`:defaults` stands for all three, alongside a custom set" do
      put_metrics_config(metric_sets: [:defaults, CatMetrics])

      assert Metrics.metric_sets() == [
               MetricSet.CPU,
               MetricSet.Disk,
               MetricSet.Memory,
               CatMetrics
             ]
    end

    test "a set's name from before the metrics extension still samples" do
      put_metrics_config(metric_sets: [MetricSet.Memory])
      through_new = Metrics.sample() |> Map.keys() |> Enum.sort()

      put_metrics_config(metric_sets: [NervesHubLink.Extensions.Health.MetricSet.Memory])

      assert Metrics.sample() |> Map.keys() |> Enum.sort() == through_new
    end

    test "can be turned off entirely" do
      put_metrics_config(metric_sets: [])

      assert Metrics.metric_sets() == []
      assert Metrics.sample() == %{}
    end
  end

  describe "sample/0" do
    test "samples each configured set, with its keys normalized" do
      put_metrics_config(metric_sets: [CatMetrics])

      assert Metrics.sample() == %{"cats_seen" => 4, "cats_fed" => 2}
    end

    test "includes metrics given directly in the config" do
      put_metrics_config(metric_sets: [], metrics: %{"battery" => 87})

      assert Metrics.sample() == %{"battery" => 87}
    end

    test "calls an MFA for a metric's value" do
      put_metrics_config(metric_sets: [], metrics: %{"battery" => {Battery, :percent, []}})

      assert Metrics.sample() == %{"battery" => 87}
    end
  end

  describe "configuration" do
    test "falls back to where health kept metric sets" do
      put_health_config(metric_sets: [CatMetrics])

      assert Metrics.metric_sets() == [CatMetrics]
    end

    test "falls back to where health kept its own metrics" do
      put_health_config(metric_sets: [], metrics: %{"battery" => 87})

      assert Metrics.sample() == %{"battery" => 87}
    end

    test "prefers `metrics:` over the health config" do
      put_metrics_config(metric_sets: [CatMetrics])
      put_health_config(metric_sets: [])

      assert Metrics.metric_sets() == [CatMetrics]
    end

    test "a setting of its own doesn't take away health's metric sets" do
      # A device adding `metrics: [sample_interval_seconds: 30]` names nothing
      # about what to sample, and has to go on sampling what it did before.
      put_metrics_config(sample_interval_seconds: 30)
      put_health_config(metric_sets: [CatMetrics])

      assert Metrics.metric_sets() == [CatMetrics]
    end
  end

  defp put_metrics_config(config), do: Application.put_env(:nerves_hub_link, :metrics, config)
  defp put_health_config(config), do: Application.put_env(:nerves_hub_link, :health, config)

  defp restore(key, nil), do: Application.delete_env(:nerves_hub_link, key)
  defp restore(key, value), do: Application.put_env(:nerves_hub_link, key, value)
end
