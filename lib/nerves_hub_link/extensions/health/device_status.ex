# SPDX-FileCopyrightText: 2024 Jon Carstens
# SPDX-FileCopyrightText: 2024 Lars Wikman
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule NervesHubLink.Extensions.Health.DeviceStatus do
  @moduledoc """
  Structure for device status.
  """

  # Msgpax is optional, so only derive its protocol when it's actually available
  if Code.ensure_loaded?(Msgpax.Packer) do
    @derive [Jason.Encoder, Msgpax.Packer]
  else
    @derive Jason.Encoder
  end

  defstruct [:timestamp, :alarms, :metrics]

  @type alarm_id() :: String.t()
  @type alarm_description() :: String.t()

  @type t() :: %__MODULE__{
          timestamp: DateTime.t(),
          alarms: %{alarm_id() => alarm_description()},
          metrics: %{String.t() => number()}
        }

  @spec new(Access.t()) :: t()
  def new(kv) do
    %__MODULE__{
      timestamp: kv[:timestamp] || DateTime.utc_now(),
      alarms: kv[:alarms] || %{},
      metrics: kv[:metrics] || %{}
    }
  end
end
