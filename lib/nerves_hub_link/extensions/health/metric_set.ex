defmodule NervesHubLink.Extensions.Health.MetricSet do
  @moduledoc """
  Behaviour for implementing a custom metric set to be used in a report.
  """

  @callback metrics() :: %{(String.t() | atom()) => number()}
end
