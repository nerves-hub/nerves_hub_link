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

  Health carries metrics too, alongside metadata, alarms and checks, in one
  report. A device reporting every minute therefore sends all of it every
  minute, and most of what that costs is the part that never changes. Split
  out, the numbers run at their own pace: report metrics as often as anyone
  wants to watch them, and health as often as what health carries actually
  changes.

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

  Readings are taken by `NervesHubLink.Metrics.Sampler` on its own interval,
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

  What is sampled is `NervesHubLink.Metrics`'s; how often, and how much is
  held, is `NervesHubLink.Metrics.Sampler`'s.

  See the [extensions guide](guides/extensions.md#metrics), and NervesHub's
  `docs/metrics.md` for the protocol.
  """

  use NervesHubLink.Extensions, name: "metrics", version: "0.1.0"

  alias NervesHubLink.Metrics.Sampler

  require Logger

  # The platform's cap on one message. Sending more loses the excess
  # server-side, so a flush goes out in chunks of this. Not configurable: it is
  # NervesHub's number, not this device's.
  @max_reports_per_message 60

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
      [] ->
        state

      reports ->
        case push("report", %{"reports" => reports}) do
          {:ok, _ref} ->
            :ok = Sampler.sent(length(reports))
            send_reports(state)

          {:error, _reason} ->
            state
        end
    end
  end
end
