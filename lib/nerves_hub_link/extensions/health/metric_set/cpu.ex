# SPDX-FileCopyrightText: 2025 Josh Kalderimis
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule NervesHubLink.Extensions.Health.MetricSet.CPU do
  @moduledoc false

  # Moved to `NervesHubLink.MetricSet.CPU`. Kept so a device that names this
  # module in `metric_sets` goes on sampling the same numbers rather than
  # losing them to an undefined module.

  @behaviour NervesHubLink.MetricSet

  @impl NervesHubLink.MetricSet
  @deprecated "Use NervesHubLink.MetricSet.CPU.sample/0 instead"
  defdelegate sample(), to: NervesHubLink.MetricSet.CPU
end
