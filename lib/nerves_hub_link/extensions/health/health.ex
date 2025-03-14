defmodule NervesHubLink.Extensions.Health do
  @moduledoc """
  The Health Extension.

  Provides metrics, metadata and alarms to allow building an understanding of
  the operational state of a device. The device's "health". This information
  is reported over the extensions mechanism to NervesHub for display, alerting
  and more.
  """

  use NervesHubLink.Extensions, name: "health", version: "0.0.1"

  alias NervesHubLink.Extensions.Health.DefaultReport
  alias NervesHubLink.Extensions.Health.DeviceStatus

  require Logger

  @doc """
  Request a health report be sent asynchronously.

  ## Examples

      iex> NervesHubLink.Extensions.Health.send_report()
      :ok

  """
  @spec send_report() :: :ok
  def send_report() do
    GenServer.cast(__MODULE__, "send_report")
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
    GenServer.call(__MODULE__, "report_sent?")
  end

  @impl GenServer
  def init(_opts) do
    # Does not send an initial report, server requests one
    {:ok, %{report_sent: false}}
  end

  @impl GenServer
  def handle_cast("send_report", state) do
    handle_event("check", nil, state)
  end

  @impl GenServer
  def handle_call("report_sent?", _args, state) do
    {:reply, state[:report_sent], state}
  end

  @impl NervesHubLink.Extensions
  def handle_event("check", _msg, state) do
    case push("report", %{"value" => check_health()}) do
      {:ok, _} -> {:noreply, %{state | report_sent: true}}
      {:error, _reason} -> {:noreply, %{state | report_sent: false}}
    end
  end

  @spec check_health(module()) :: DeviceStatus.t() | nil
  def check_health(default_report \\ DefaultReport) do
    config = Application.get_env(:nerves_hub, :health, [])
    report = Keyword.get(config, :report, default_report)

    if report do
      :alarm_handler.clear_alarm(NervesHubLink.Extensions.Health.CheckFailed)

      alarms =
        case :gen_event.which_handlers(:alarm_handler) do
          [:alarm_handler] ->
            # Using default alarm handler, it is not to be used
            # it will be very confusing, just send no alarms
            %{}

          _ ->
            report.alarms()
        end

      DeviceStatus.new(
        timestamp: report.timestamp(),
        metadata: report.metadata(),
        alarms: alarms,
        metrics: report.metrics(),
        checks: report.checks()
      )
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
      :alarm_handler.set_alarm({NervesHubLink.Extensions.Health.CheckFailed, [reason: reason]})

      DeviceStatus.new(
        timestamp: DateTime.utc_now(),
        metadata: %{},
        alarms: %{to_string(NervesHubLink.Extensions.Health.CheckFailed) => reason},
        metrics: %{},
        checks: %{}
      )
  end
end
