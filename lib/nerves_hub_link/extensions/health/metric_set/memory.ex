# SPDX-FileCopyrightText: 2025 Josh Kalderimis
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule NervesHubLink.Extensions.Health.MetricSet.Memory do
  @moduledoc false

  # Moved to `NervesHubLink.MetricSet.Memory`. Kept so a device that names this
  # module in `metric_sets` goes on sampling the same numbers rather than
  # losing them to an undefined module.

  @behaviour NervesHubLink.MetricSet

  @impl NervesHubLink.MetricSet
  @deprecated "Use NervesHubLink.MetricSet.Memory.sample/0 instead"
  defdelegate sample(), to: NervesHubLink.MetricSet.Memory
end
