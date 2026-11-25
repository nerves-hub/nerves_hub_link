# SPDX-FileCopyrightText: 2026 Josh Kalderimis
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule NervesHubLink.Extensions.Metrics do
  @moduledoc """
  The Metrics Extension, version 0.1.0.

  Sends the numbers a device measures about itself - CPU temperature, memory
  used, load average, and whatever else its firmware knows how to read - and
  nothing else.

  Health carries metrics too, alongside its alarms and checks, in one report. A
  device reporting every minute therefore sends all of it every minute, and
  most of what that costs is the part that never changes. Split out, the
  numbers run at their own pace: report metrics as often as anyone wants to
  watch them, and health as often as what health carries actually changes.

  Named in `extension_modules` by default, so there is nothing to turn on:

      config :nerves_hub_link,
        extension_modules: [
          NervesHubLink.Extensions.Alarms,
          NervesHubLink.Extensions.Geo,
          NervesHubLink.Extensions.Metrics,
          NervesHubLink.Extensions.NetworkIdentity
        ]

  Like every extension, it sends nothing until NervesHub asks the device to
  attach it, and NervesHub only asks if the product has the extension enabled.
  A NervesHub without ClickHouse doesn't offer it at all and takes metrics
  through health instead, so a device talking to one should name
  `NervesHubLink.Extensions.Health` as well.

  ## What is sent

  NervesHub asks for a report (`metrics:check`) on one timer per connection:
  every fifteen minutes while nobody is looking at the device, and every minute
  while somebody is. The answer (`metrics:report`) carries every reading taken
  since the last one, each with the time it was taken, up to sixty of them.

  Readings are taken by `NervesHubLink.Extensions.Metrics.Sampler` on its own interval,
  from the first time NervesHub attaches this extension, so being asked rarely
  costs a device no detail and a disconnection costs it nothing at all.
  `flush/0` sends what is waiting without being asked.

  While this extension is attached, `NervesHubLink.Extensions.Health` leaves
  metrics out of its reports, so the two don't both report them.

  ## Configuration

      config :nerves_hub_link,
        metrics: [
          metric_sets: [:defaults, MyApp.BatteryMetrics],
          sample_interval_seconds: 60,
          max_samples: 60
        ]

  `:metric_sets` names modules implementing
  `NervesHubLink.Extensions.Metrics.MetricSet`, with `:defaults` standing in
  for the CPU, Disk and Memory sets. `:metrics` is for a handful of numbers
  that don't warrant a set of their own; each value is either a number or an
  `{module, function, args}` tuple called when the metrics are sampled. Both
  keys lived under `health:` before this extension existed, and are still read
  from there when `metrics:` doesn't name them, so a device configured for
  health samples exactly what it always did.

  `sample/0` and `metric_sets/0` are plain functions and answer whether or not
  this extension is attached, because a health report samples through them too.
  How often readings are taken, and how many are held, is
  `NervesHubLink.Extensions.Metrics.Sampler`'s.

  See the [extensions guide](guides/extensions.md#metrics), and NervesHub's
  `docs/metrics.md` for the protocol.
  """

  use NervesHubLink.Extensions, name: "metrics", version: "0.1.0"

  alias NervesHubLink.ConfigValue
  alias NervesHubLink.Extensions.Metrics.MetricSet
  alias NervesHubLink.Extensions.Metrics.Sampler

  require Logger

  # The platform's cap on one message. Sending more loses the excess
  # server-side, so a flush goes out in chunks of this. Not configurable: it is
  # NervesHub's number, not this device's.
  @max_reports_per_message 60

  @default_metric_sets [
    MetricSet.CPU,
    MetricSet.Disk,
    MetricSet.Memory
  ]

  @doc """
  Whether the extension is attached, and so whether metrics are being sent here
  rather than in health reports.

  The extension's process only runs while it is attached.
  """
  @spec attached?() :: boolean()
  def attached?(), do: Process.whereis(__MODULE__) != nil

  @doc """
  Send the readings that are waiting, without waiting to be asked.

  ## Examples

      iex> NervesHubLink.Extensions.Metrics.flush()
      :ok

  """
  @spec flush() :: :ok
  def flush(), do: GenServer.cast(__MODULE__, :flush)

  @doc """
  Take a reading from every configured metric set and metric.

  Raises whatever a metric set raises. The callers here either hold an alarm
  for it (`NervesHubLink.Extensions.Health`) or drop the sample
  (`NervesHubLink.Extensions.Metrics.Sampler`), and both are better placed to say what a
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

  @impl GenServer
  def init(_opts) do
    # The sampler holds off until something is going to ask for the readings,
    # which is this. It keeps sampling from here on, whatever the connection
    # does and whether or not this extension is still attached.
    :ok = Sampler.start_sampling()

    # No report here: NervesHub asks for one shortly after attaching, and
    # answering the attach as well would have a fleet that reconnected
    # together report together.
    {:ok, %{}}
  end

  @impl GenServer
  def handle_cast(:flush, state) do
    {:noreply, send_reports(state)}
  end

  @impl NervesHubLink.Extensions
  def handle_event("check", _payload, state) do
    {:noreply, send_reports(state)}
  end

  def handle_event(event, _payload, state) do
    Logger.debug("[#{inspect(__MODULE__)}] ignoring unknown event: #{inspect(event)}")

    {:noreply, state}
  end

  # In chunks, because the platform drops whatever one message carries past its
  # cap. Each chunk is dropped from the sampler only once it has gone, so a
  # socket that dies part way through a flush leaves the rest for the next one.
  defp send_reports(state) do
    case Sampler.take(@max_reports_per_message) do
      {[], _cursor} ->
        state

      {reports, cursor} ->
        case push("report", %{"reports" => reports}) do
          {:ok, _ref} ->
            :ok = Sampler.sent(cursor)
            send_reports(state)

          {:error, _reason} ->
            state
        end
    end
  end
end
