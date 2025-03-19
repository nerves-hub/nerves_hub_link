# SPDX-FileCopyrightText: 2024 Jon Carstens
# SPDX-FileCopyrightText: 2024 Lars Wikman
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule NervesHubLink.Extensions.Health.Report do
  @moduledoc """
  Behaviour for implementing a custom health report.

  The `NervesHubLink.Extensions.Health.DefaultReport` has a lot of easy
  customization options available. If you want an entirely custom report or
  need exact control over how the generation of data happens then using this
  gives you that possibility.
  """
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
