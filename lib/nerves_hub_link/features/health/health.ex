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
    config = Application.get_env(:nerves_hub, :health, [])
    report = Keyword.get(config, :report, default_report)

    if report do
      :alarm_handler.clear_alarm(NervesHubLink.Features.Health.CheckFailed)

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
      :alarm_handler.set_alarm({NervesHubLink.Features.Health.CheckFailed, [reason: reason]})

      DeviceStatus.new(
        timestamp: DateTime.utc_now(),
        metadata: %{},
        alarms: %{to_string(NervesHubLink.Features.Health.CheckFailed) => reason},
        metrics: %{},
        checks: %{}
      )
  end
end
