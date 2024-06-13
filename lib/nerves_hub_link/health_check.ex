defmodule NervesHubLink.HealthCheck do
    @moduledoc """

    """

    alias Nerves.Runtime.KV
    alias NervesHubLink.HealthCheck.DeviceStatus

    require Logger
    def run_check do
        config = Application.get_env(:nerves_hub_link, :health)
        if config == false do
            # No check at all, disabled
            false
        else
            report = config[:report] || NervesHubLink.HealthCheck.DefaultReport
            DeviceStatus.new(
                device_id: report.device_id(),
                timestamp: report.timestamp(),
                metadata: report.metadata(),
                alarms: report.alarms(),
                metrics: report.alarms(),
                peripherals: report.peripherals()
            )
        end
    end
end