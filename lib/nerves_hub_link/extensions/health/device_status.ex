# SPDX-FileCopyrightText: 2024 Jon Carstens
# SPDX-FileCopyrightText: 2024 Lars Wikman
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule NervesHubLink.Extensions.Health.DeviceStatus do
  @moduledoc """
  Structure for device status.
  """

  @derive Jason.Encoder
  defstruct timestamp: DateTime.utc_now(),
            metadata: %{},
            alarms: %{},
            metrics: %{},
            checks: %{},
            connectivity: %{}

  @type alarm_id() :: String.t()
  @type alarm_description() :: String.t()
  @type interface_identifier() :: String.t()

  @type connection_status :: :lan | :internet | :disconnected
  @type interface_type :: :ethernet | :wifi | :mobile | :local | :unknown

  @type t() :: %__MODULE__{
          timestamp: DateTime.t(),
          metadata: %{String.t() => String.t()},
          alarms: %{alarm_id() => alarm_description()},
          metrics: %{String.t() => number()},
          checks: %{String.t() => %{pass: boolean(), note: String.t()}},
          connectivity: %{
            interface_identifier() => %{
              type: interface_type(),
              present: boolean(),
              state: atom(),
              connection_status: connection_status(),
              # Such as RSSI and others
              metrics: %{String.t() => number()},
              # Network name, telecom operator and similar data
              metadata: %{String.t() => String.t()}
            }
          }
        }

  @spec new(Access.t()) :: t()
  def new(kv) do
    %__MODULE__{
      timestamp: kv[:timestamp],
      metadata: kv[:metadata],
      alarms: kv[:alarms],
      metrics: kv[:metrics],
      checks: kv[:checks]
    }
  end
end
