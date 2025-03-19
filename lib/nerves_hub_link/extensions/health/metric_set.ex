# SPDX-FileCopyrightText: 2025 Josh Kalderimis
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule NervesHubLink.Extensions.Health.MetricSet do
  @moduledoc """
  Behaviour for implementing a custom metric set to be used in a report.
  """

  @callback sample() :: %{(String.t() | atom()) => number()}
end
