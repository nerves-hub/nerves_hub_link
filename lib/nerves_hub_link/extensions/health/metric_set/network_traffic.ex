# SPDX-FileCopyrightText: 2026 Josh Kalderimis
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule NervesHubLink.Extensions.Health.MetricSet.NetworkTraffic do
  @moduledoc false

  # Moved to `NervesHubLink.MetricSet.NetworkTraffic`. Kept so a device that names this
  # module in `metric_sets` goes on sampling the same numbers rather than
  # losing them to an undefined module.

  @behaviour NervesHubLink.MetricSet

  @impl NervesHubLink.MetricSet
  @deprecated "Use NervesHubLink.MetricSet.NetworkTraffic.sample/0 instead"
  defdelegate sample(), to: NervesHubLink.MetricSet.NetworkTraffic
end
