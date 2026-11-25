# SPDX-FileCopyrightText: 2026 Josh Kalderimis
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule NervesHubLink.Metrics do
  @moduledoc """
  The numbers a device measures about itself.

  Sampling is shared: `NervesHubLink.Extensions.Metrics` and the health report
  both come through here, so metric sets are configured once and are sampled
  the same way whichever of the two NervesHub attaches.

      config :nerves_hub_link,
        metrics: [
          metric_sets: [:defaults, MyApp.BatteryMetrics],
          metrics: %{"firmware_slot" => {MyApp, :slot, []}}
        ]

  `:metric_sets` names modules implementing `NervesHubLink.Metrics.MetricSet`, with
  `:defaults` standing in for the CPU, Disk and Memory sets. `:metrics` is for a handful of numbers that don't
  warrant a set of their own; each value is either a number or an
  `{module, function, args}` tuple called when the metrics are sampled.

  Both keys lived under `health:` before the metrics extension existed, and are
  still read from there when `metrics:` doesn't name them, so a device
  configured for health samples exactly what it always did.
  """

  alias NervesHubLink.ConfigValue
  alias NervesHubLink.Metrics.MetricSet

  @default_metric_sets [
    MetricSet.CPU,
    MetricSet.Disk,
    MetricSet.Memory
  ]

  @doc """
  Take a reading from every configured metric set and metric.

  Raises whatever a metric set raises. The callers here either hold an alarm
  for it (`NervesHubLink.Extensions.Health`) or drop the sample
  (`NervesHubLink.Metrics.Sampler`), and both are better placed to say what a
  failed reading means than this is.
  """
  @spec sample() :: %{String.t() => number()}
  def sample() do
    Map.merge(configured_metrics(), metric_set_samples())
  end

  @doc """
  The metric sets this device samples.

  `:default` and `:defaults` in the configured list stand for
  #{inspect(@default_metric_sets)}.
  """
  @spec metric_sets() :: [module()]
  def metric_sets() do
    config(:metric_sets, @default_metric_sets)
    |> List.wrap()
    |> Enum.flat_map(fn
      set when set in [:default, :defaults] -> @default_metric_sets
      set -> [set]
    end)
  end

  defp metric_set_samples() do
    for metric_set <- metric_sets(),
        {key, value} <- metric_set.sample(),
        into: %{},
        do: {ConfigValue.key(key), value}
  end

  defp configured_metrics() do
    for {key, value_or_mfa} <- config(:metrics, %{}), into: %{} do
      {ConfigValue.key(key), ConfigValue.resolve(value_or_mfa)}
    end
  end

  # Key by key rather than one block or the other: the metrics extension has
  # settings of its own, and configuring one of those shouldn't silently take
  # away the metric sets a device named under `health:` years ago.
  defp config(key, default) do
    case Keyword.fetch(Application.get_env(:nerves_hub_link, :metrics, []), key) do
      {:ok, value} ->
        value

      :error ->
        Application.get_env(:nerves_hub_link, :health, [])
        |> Keyword.get(key, default)
    end
  end
end
