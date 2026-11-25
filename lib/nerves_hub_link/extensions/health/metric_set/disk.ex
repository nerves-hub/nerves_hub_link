# SPDX-FileCopyrightText: 2025 Josh Kalderimis
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule NervesHubLink.Extensions.Health.MetricSet.Disk do
  @moduledoc false

  # Moved to `NervesHubLink.Extensions.Metrics.MetricSet.Disk`. Kept so a device that names this
  # module in `metric_sets` goes on sampling the same numbers rather than
  # losing them to an undefined module.

  @behaviour NervesHubLink.Extensions.Metrics.MetricSet

  @impl NervesHubLink.Extensions.Metrics.MetricSet
  @deprecated "Use NervesHubLink.Extensions.Metrics.MetricSet.Disk.sample/0 instead"
  defdelegate sample(), to: NervesHubLink.Extensions.Metrics.MetricSet.Disk
end
