defmodule NervesHubLink.Extensions.Health.MetricSet.Memory do
  @moduledoc """
  Health report metrics for total, available, and used (percentage) memory.

  The keys used in the report are:
    - mem_size_mb: Total memory size in megabytes
    - mem_used_mb: Used memory size in megabytes
    - mem_used_percent: Used memory percentage
  """
  @behaviour NervesHubLink.Extensions.Health.MetricSet

  @impl NervesHubLink.Extensions.Health.MetricSet
  def sample() do
    {free_output, 0} = System.cmd("free", [])
    [_title_row, memory_row | _] = String.split(free_output, "\n")
    [_title_column | memory_columns] = String.split(memory_row)
    [size_kb, used_kb, _, _, _, _] = Enum.map(memory_columns, &String.to_integer/1)
    size_mb = round(size_kb / 1000)
    used_mb = round(used_kb / 1000)
    used_percent = round(used_mb / size_mb * 100)

    %{mem_size_mb: size_mb, mem_used_mb: used_mb, mem_used_percent: used_percent}
  rescue
    _ ->
      %{}
  end
end
