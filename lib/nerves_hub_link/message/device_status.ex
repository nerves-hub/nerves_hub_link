defmodule NervesHubLink.Message.DeviceStatus do
  @moduledoc """
  Structure for device status.
  """

  @derive Jason.Encoder
  defstruct device_id: "",
            timestamp: DateTime.utc_now(),
            metadata: %{},
            alarms: %{},
            metrics: %{},
            peripherals: %{}

  @type alarm_id() :: String.t()
  @type alarm_description() :: String.t()

  @type t() :: %__MODULE__{
          timestamp: DateTime.t(),
          metadata: %{String.t() => String.t()},
          alarms: %{alarm_id() => alarm_description()},
          metrics: %{String.t() => number()},
          peripherals: %{String.t() => DeviceStatus.Peripheral.t()}
        }

  alias __MODULE__, as: DS

  def new(kv) do
    %DS{
      device_id: kv[:device_id],
      timestamp: kv[:timestamp],
      metadata: kv[:metadata],
      alarms: kv[:alarms],
      metrics: kv[:metrics],
      peripherals: kv[:peripherals]
    }
  end
end
