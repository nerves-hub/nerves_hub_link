defmodule NervesHubLink.Message.DeviceStatus do
  @moduledoc """
  Structure for device status.
  """

  @derive Jason.Encoder
  defstruct device_id: "",
            timestamp: "",
            metadata: %{},
            alarms: %{},
            metrics: %{},
            peripherals: %{}

  @type alarm_id() :: String.t()
  @type alarm_description() :: String.t()

  @type t() :: %__MODULE__{
    device_id: String.t(),
    timestamp: String.t(), # iso8601
    metadata: %{String.t() => String.t()},
    alarms: %{alarm_id() => alarm_description()},
    metrics: %{String.t() => number()},
    peripherals: %{String.t() => DeviceStatus.Peripheral.t()}
  }

end
