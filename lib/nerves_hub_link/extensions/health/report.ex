defmodule NervesHubLink.Extensions.Health.Report do
  alias NervesHubLink.Extensions.Health.DeviceStatus

  @callback timestamp() :: DateTime.t()
  @callback metadata() :: %{String.t() => String.t()}
  @callback alarms() :: %{String.t() => String.t()}
  @callback metrics() :: %{String.t() => number()}
  @callback checks() :: %{String.t() => %{pass: boolean(), note: String.t()}}
  @callback connectivity() :: %{
              DeviceStatus.interface_identifer() => %{
                type: DeviceStatus.interface_type(),
                present: boolean(),
                state: atom(),
                connection_status: DeviceStatus.connection_status(),
                # Such as RSSI and others
                metrics: %{String.t() => number()},
                # Network name, telecom operator and similar data
                metadata: %{String.t() => String.t()}
              }
            }
end
