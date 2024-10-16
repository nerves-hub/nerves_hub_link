defmodule NervesHubLink.HealthCheck.Report do
  alias NervesHubLink.Message.DeviceStatus.Peripheral

  @callback timestamp() :: DateTime.t()
  @callback metadata() :: %{String.t() => String.t()}
  @callback alarms() :: %{String.t() => String.t()}
  @callback metrics() :: %{String.t() => number()}
  @callback peripherals() :: %{String.t() => Peripheral.t()}
end
