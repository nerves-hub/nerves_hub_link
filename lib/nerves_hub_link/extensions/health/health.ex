# SPDX-FileCopyrightText: 2024 Jon Carstens
# SPDX-FileCopyrightText: 2024 Lars Wikman
# SPDX-FileCopyrightText: 2025 Elin Olsson
# SPDX-FileCopyrightText: 2025 Josh Kalderimis
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule NervesHubLink.Extensions.Health do
  @moduledoc """
  The Health Extension.

  Reports the device's metrics and alarms to a NervesHub that has no extension
  for them: one without ClickHouse takes metrics here, and one older than
  `NervesHubLink.Extensions.Alarms` takes alarms here.

  Metadata is not part of a report. It says what a device is rather than how it
  is doing, and NervesHub holds it against the connection, so it is sent once
  per connection on the device channel. See `c:NervesHubLink.Client.device_metadata/0`.

  While `NervesHubLink.Extensions.Alarms` or `NervesHubLink.Extensions.Metrics`
  is attached, what it carries is sent there instead and left out of health
  reports.
  """

  use NervesHubLink.Extensions, name: "health", version: "0.0.1"

  alias NervesHubLink.Alarms
  alias NervesHubLink.Extensions.Alarms, as: AlarmsExtension
  alias NervesHubLink.Extensions.Health.DefaultReport
  alias NervesHubLink.Extensions.Health.DeviceStatus
  alias NervesHubLink.Extensions.Metrics, as: MetricsExtension

  require Logger

  @doc """
  Request a health report be sent asynchronously.

  ## Examples

      iex> NervesHubLink.Extensions.Health.send_report()
      :ok

  """
  @spec send_report() :: :ok
  def send_report() do
    GenServer.call(__MODULE__, :send_report)
  end

  @doc """
  Confirms if a health report has been sent.

  ## Examples

      iex> NervesHubLink.Extensions.Health.report_sent?()
      false

      iex> NervesHubLink.Extensions.Health.send_report()
      :ok

      iex> NervesHubLink.Extensions.Health.report_sent?()
      true

  """
  @spec report_sent?() :: boolean()
  def report_sent?() do
    GenServer.call(__MODULE__, :report_sent?)
  end

  @impl GenServer
  def init(_opts) do
    # Does not send an initial report, server requests one
    {:ok, %{report_sent: false}}
  end

  @impl GenServer
  def handle_call(:send_report, _args, state) do
    case send_health_report(state) do
      {:ok, state} -> {:reply, :ok, state}
      {:error, state} -> {:reply, :error, state}
    end
  end

  @impl GenServer
  def handle_call(:report_sent?, _args, state) do
    {:reply, state[:report_sent], state}
  end

  @impl NervesHubLink.Extensions
  def handle_event("check", _msg, state) do
    case send_health_report(state) do
      {:ok, state} -> {:noreply, state}
      {:error, state} -> {:noreply, state}
    end
  end

  defp send_health_report(state) do
    case report_value() do
      nil ->
        # Nothing left to say: the alarms and the metrics are both going out
        # through their own extensions. A report carrying only a timestamp
        # still costs a message, a stored reading of nothing, and a
        # `device.health_reported` event with nothing in it.
        {:ok, state}

      value ->
        case push("report", %{"value" => value}) do
          {:ok, _} -> {:ok, %{state | report_sent: true}}
          {:error, _reason} -> {:error, state}
        end
    end
  end

  # A plain map carrying only what this extension is still responsible for,
  # rather than a `DeviceStatus`. NervesHub reads an empty `alarms` map as "no
  # alarms" and would clear everything the alarms extension had raised, where a
  # missing key says nothing about alarms at all.
  #
  # Those keys are also not collected in the first place. Sampling metrics
  # shells out to `free` and `df`, which is not work to do every check to throw
  # the answer away because the metrics extension is sending its own.
  defp report_value() do
    case reporting_here() do
      [] -> nil
      keys -> collect(DefaultReport, keys)
    end
  end

  defp reporting_here() do
    for {extension, key} <- [{AlarmsExtension, :alarms}, {MetricsExtension, :metrics}],
        not extension.attached?(),
        do: key
  end

  @spec check_health(module()) :: DeviceStatus.t() | nil
  def check_health(default_report \\ DefaultReport) do
    case collect(default_report, [:alarms, :metrics]) do
      nil -> nil
      collected -> DeviceStatus.new(Map.to_list(collected))
    end
  end

  # The timestamp and whichever of `keys` the caller asked for, as a plain map.
  # `nil` when reporting is switched off.
  #
  # A report module that raises costs its report, not the connection: the
  # failure is reported as an alarm of its own instead. That alarm goes out
  # through whichever extension is carrying alarms, which is why the failure
  # path answers with the same keys as the rest.
  defp collect(default_report, keys) do
    config = Application.get_env(:nerves_hub_link, :health, [])
    report = Keyword.get(config, :report, default_report)

    if report do
      Alarms.clear_alarm(NervesHubLink.Extensions.Health.CheckFailed)

      Map.new([:timestamp | keys], fn
        :timestamp -> {:timestamp, report.timestamp()}
        :alarms -> {:alarms, report.alarms()}
        :metrics -> {:metrics, report.metrics()}
      end)
    end
  rescue
    err ->
      reason =
        try do
          inspect(err)
        rescue
          _ ->
            "unknown error"
        end

      Logger.error("Health check failed due to error: #{reason}")

      Alarms.clear_alarm(NervesHubLink.Extensions.Health.CheckFailed)
      Alarms.set_alarm({NervesHubLink.Extensions.Health.CheckFailed, [reason: reason]})

      Map.new([:timestamp | keys], fn
        :timestamp ->
          {:timestamp, DateTime.utc_now()}

        :alarms ->
          {:alarms, %{to_string(NervesHubLink.Extensions.Health.CheckFailed) => reason}}

        :metrics ->
          {:metrics, %{}}
      end)
  end
end
