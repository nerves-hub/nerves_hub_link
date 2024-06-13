defmodule NervesHubLink.Message.DeviceStatus.Peripheral do
  @moduledoc """
  Information about and status of a subsystem of a hardware device.
  Typically used for sensors, ports and other peripherals.
  """

  @derive Jason.Encoder
  defstruct id: "",
            name: "",
            device_type: "",
            connection_type: "",
            connection_id: "",
            enabled: false,
            tested: false,
            working: false,
            errors: []

  @typedoc """
  ### Fields
  * `id` - An identifier for this device. Should ideally be quite unique but at least unique within the device.
  * `name` - Human-friendly name or part number. Does not need to be unique but could be helpful. Eg. "front USB", "rear USB"
  * `device_type` - Category of device "display", "sensor", "port". No particular taxonomy. Intended to be helpful for people.
  * `connection_type` - How is the device communicated with: "i2c", "gpio", "kernel_driver"
  * `connection_id` - Where is is connected to: "i2c-0", "gpio-5", "/dev/backlight"
  * `enabled` - Whether or not the hardware is enabled and intended to work. Elixir convention of `boolean?` is not used for the benefit of other systems.
  * `tested` - Whether or not the hardware is possible to automatically test. Elixir convention of `boolean?` is not used for the benefit of other systems.
  * `working` - Whether or not the hardware seems to be working according to test. Elixir convention of `boolean?` is not used for the benefit of other systems.
  * `errors` - List of error message strings describing errors encountered during tests.
  """

  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t(),
          device_type: String.t(),
          connection_type: String.t(),
          connection_id: String.t(),
          enabled: boolean(),
          tested: boolean(),
          working: boolean(),
          errors: list(String.t())
        }
end
