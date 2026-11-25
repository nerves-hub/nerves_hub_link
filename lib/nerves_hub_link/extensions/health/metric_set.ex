# SPDX-FileCopyrightText: 2025 Josh Kalderimis
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule NervesHubLink.Extensions.Health.MetricSet do
  @moduledoc false

  # Moved to `NervesHubLink.Extensions.Metrics.MetricSet`: metric sets are sampled by
  # `NervesHubLink.Extensions.Metrics` as well as by a health report, so they
  # no longer belong under the health extension. Kept so a module that
  # implements this behaviour goes on compiling and sampling.

  @callback sample() :: %{(String.t() | atom()) => number()}
end
