# SPDX-FileCopyrightText: 2025 Josh Kalderimis
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule NervesHubLink.Extensions.Health.MetricSet.NetworkTraffic do
  @moduledoc """
  Health report metrics for bytes sent and received (total) per interface.

  The keys used in the report are:
    - [interface]_bytes_received_total: Total bytes received by the interface
    - [interface]_bytes_sent_total: Total bytes sent by the interface
  """
  @behaviour NervesHubLink.Extensions.Health.MetricSet

  require Logger

  @impl NervesHubLink.Extensions.Health.MetricSet
  def sample() do
    if File.exists?("/proc/net/dev") do
      {output, _} = System.cmd("cat", ["/proc/net/dev"])
      parse_proc_net_dev(output)
    else
      Logger.warning("[Health.MetricSet.NetworkTraffic] Network traffic metrics not available")
      %{}
    end
  rescue
    _ ->
      %{}
  end

  defp parse_proc_net_dev(output) do
    [_top, _header | data] = String.split(output, "\n")

    {_, data} = List.pop_at(data, -1)

    data
    |> Enum.map(fn line ->
      [interface, bytes_received, _, _, _, _, _, _, _, bytes_sent | _] = String.split(line)

      %{
        interface: String.replace(interface, ":", ""),
        bytes_received_total: bytes_received,
        bytes_sent_total: bytes_sent
      }
    end)
    |> Enum.reject(fn %{interface: interface} ->
      interface == "lo"
    end)
    |> Enum.map(fn data ->
      %{
        "#{data.interface}_bytes_received_total" => data.bytes_received_total,
        "#{data.interface}_bytes_sent_total" => data.bytes_sent_total
      }
    end)
    |> Enum.reduce(%{}, &Map.merge/2)
  end
end
