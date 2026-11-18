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
  @callback timestamp() :: DateTime.t()
  @callback alarms() :: %{String.t() => String.t()}
  @callback metrics() :: %{String.t() => number()}
end
