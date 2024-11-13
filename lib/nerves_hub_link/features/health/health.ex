defmodule NervesHubLink.Features.Health do
  use NervesHubLink.Features, name: "health", version: "0.0.1"

  alias NervesHubLink.Features.Health.DefaultReport
  alias NervesHubLink.Features.Health.DeviceStatus

  require Logger

  @impl GenServer
  def init(_opts) do
    # Does not send an initial report, server reports one
    {:ok, %{}}
  end

  @impl NervesHubLink.Features
  def handle_event("check", _msg, state) do
    _ = push("report", %{"value" => check_health()})
    {:noreply, state}
  end

  def check_health(default_report \\ DefaultReport) do
    report = Application.get_env(:nerves_hub_health, :report, default_report)

    if report do
      :alarm_handler.clear_alarm(NervesHubLink.Features.Health.CheckFailed)

      DeviceStatus.new(
        timestamp: report.timestamp(),
        metadata: report.metadata(),
        alarms: report.alarms(),
        metrics: report.metrics(),
        checks: report.checks()
      )
    end
  rescue
    err ->
      Logger.error("Health check failed due to error: #{inspect(err)}")
      :alarm_handler.set_alarm({NervesHubLink.Features.Health.CheckFailed, []})

      DeviceStatus.new(
        timestamp: DateTime.utc_now(),
        metadata: %{},
        alarms: %{to_string(NervesHubLink.Features.Health.CheckFailed) => []},
        metrics: %{},
        checks: %{}
      )
  end
end
