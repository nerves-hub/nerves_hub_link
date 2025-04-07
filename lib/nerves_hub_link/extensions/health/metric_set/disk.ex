# SPDX-FileCopyrightText: 2025 Josh Kalderimis
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule NervesHubLink.Extensions.Health.MetricSet.Disk do
  @moduledoc """
  Health report metrics for total, available, and used disk space.

  The keys used in the report are:
    - disk_total_kb: Total disk space in kilobytes
    - disk_available_kb: Available disk space in kilobytes
    - disk_used_percentage: Used disk space percentage
  """
  @behaviour NervesHubLink.Extensions.Health.MetricSet

  @impl NervesHubLink.Extensions.Health.MetricSet
  def sample() do
    case Application.ensure_all_started(:os_mon) do
      {:ok, _} ->
        disk_info()

      {:error, {:already_started, _}} ->
        disk_info()

      _ ->
        %{}
    end
  end

  defp disk_info() do
    # TODO: :disksup.get_disk_info/0 can be used here instead when
    # the lowest OTP version we support is 26. That function
    # returns the available disk space in KB so we don't have
    # to calculate it ourselves.
    data =
      Enum.find(:disksup.get_disk_data(), fn {key, _, _} ->
        key == ~c"/root"
      end)

    case data do
      nil ->
        %{}

      {_, total_kb, capacity_percentage} ->
        %{
          disk_total_kb: total_kb,
          disk_available_kb: round(capacity_percentage / 100 * total_kb),
          disk_used_percentage: capacity_percentage
        }
    end
  end
end
