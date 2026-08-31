# SPDX-FileCopyrightText: 2026 Josh Kalderimis
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule NervesHubLink.Extensions.ErrorReports do
  @moduledoc """
  The Error Reports Extension, version 0.1.0.

  Sends the device's exceptions, exits and explicit error reports to NervesHub,
  where they are grouped into issues you can resolve or mute. One direction
  only: nothing is ever sent back.

  Off by default. To turn it on, name it in `extension_modules` along with the
  other extensions you want, since the list replaces the defaults rather than
  adding to them:

      config :nerves_hub_link,
        extension_modules: [
          NervesHubLink.Extensions.Geo,
          NervesHubLink.Extensions.Health,
          NervesHubLink.Extensions.NetworkIdentity,
          NervesHubLink.Extensions.ErrorReports
        ]

  Like every extension, it sends nothing until NervesHub asks the device to
  attach it, and NervesHub only asks if the product has the extension enabled.

  ## What gets reported

  Anything the runtime attaches a `crash_reason` to: a process dying with an
  exception, an exit or a throw, a GenServer termination, a failed task. See
  `NervesHubLink.Extensions.ErrorReports.Handler` for why that is the signal
  rather than the log level.

  Application code can also report an error it caught and handled, with context
  the stacktrace cannot know:

      try do
        charge(order)
      rescue
        error -> NervesHubLink.report_error(error, __STACKTRACE__, group: "payments")
      end

  ## Why it batches

  A crash loop is the case this is built for. NervesHub limits how often a
  device may send rather than how much it may say, so a message carrying
  twenty-five reports costs exactly what one carrying a single report costs.
  Sending one report per message would lose most of a restart storm and keep an
  arbitrary sample of it.

  Reports collect in `NervesHubLink.Extensions.ErrorReports.Collector` from
  application start, so a crash during boot, or while the device is offline, is
  still there to send once there is a connection.

  ## Configuration

      config :nerves_hub_link,
        error_reports: [
          max_reports: 100,
          interval_seconds: 60,
          context: {MyApp.Telemetry, :error_context, []}
        ]

  See `NervesHubLink.Extensions.ErrorReports.Config`, and in particular
  `NervesHubLink.Extensions.ErrorReports.Config.context/0` for attaching device
  state such as reboot count or free memory to every report.
  """

  use NervesHubLink.Extensions, name: "error_reports", version: "0.1.0"

  alias NervesHubLink.Extensions.ErrorReports.Collector
  alias NervesHubLink.Extensions.ErrorReports.Config
  alias NervesHubLink.Extensions.ErrorReports.Report

  require Logger

  # The platform's cap on one message. Sending more loses the excess
  # server-side, so a flush goes out in chunks of this. Not configurable: it is
  # NervesHub's number, not this device's.
  @max_reports_per_message 25

  @doc """
  Send whatever has collected, without waiting for the next flush.

  ## Examples

      iex> NervesHubLink.Extensions.ErrorReports.flush()
      :ok

  """
  @spec flush() :: :ok
  def flush(), do: GenServer.cast(__MODULE__, :flush)

  @impl GenServer
  def init(_opts) do
    {:ok, %{}, {:continue, :schedule}}
  end

  @impl GenServer
  def handle_continue(:schedule, state) do
    {:noreply, schedule(state)}
  end

  @impl GenServer
  def handle_cast(:flush, state) do
    {:noreply, send_reports(state)}
  end

  @impl GenServer
  def handle_info(:flush, state) do
    {:noreply, state |> send_reports() |> schedule()}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl NervesHubLink.Extensions
  def handle_event(event, _payload, state) do
    # Nothing is asked of this extension, so anything arriving is a NervesHub
    # that knows something this device does not.
    Logger.debug("[#{inspect(__MODULE__)}] ignoring unknown event: #{inspect(event)}")

    {:noreply, state}
  end

  defp schedule(state) do
    _ = Process.send_after(self(), :flush, Config.interval())

    state
  end

  # In chunks, because the platform drops whatever one message carries past its
  # cap. Each chunk is dropped from the collector only once it has gone, so a
  # socket that dies part way through a flush leaves the rest for the next one.
  defp send_reports(state) do
    case Collector.take(@max_reports_per_message) do
      [] ->
        state

      reports ->
        # Gathered once per batch rather than per report, and here rather than
        # in the crashing process: reading device state is not free, and the
        # moment of the crash is the worst time to pay for it.
        context = Config.context()
        reports = Enum.map(reports, &Report.put_context(&1, context))

        case push("report", %{"reports" => reports}) do
          {:ok, _ref} ->
            :ok = Collector.sent(length(reports))
            send_reports(state)

          {:error, _reason} ->
            state
        end
    end
  end
end
