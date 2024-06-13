defmodule NervesHubLink.HealthCheck do
    @moduledoc """

    Default config means not adding anything.

    Overriding config could be small:

    ```
    config :nerves_hub_link, :health,
        metadata: [organisation: "Biscuits Inc.", flavor: "chocolate"]
    ```

    Slightly more dynamic:

    ```
    config :nerves_hub_link, :health,
        metrics: [special_number: {System, :unique_integer, []}]
        
    ```

    Or completely custom:

    ```
    config :nerves_hub_link, :health, report: BiscuitBoard.HealthReport
    ```
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