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
    otp_version = :erlang.system_info(:otp_release) |> List.to_integer()

    case Application.ensure_all_started(:os_mon) do
      {:ok, _} ->
        disk_info(otp_version)

      {:error, {:already_started, _}} ->
        disk_info(otp_version)

      _ ->
        %{}
    end
  end

  defp disk_info(otp_version) when otp_version >= 26 do
    data =
      Enum.find(:disksup.get_disk_info(), fn {key, _, _, _} ->
        key == ~c"/root"
      end)

    case data do
      nil ->
        %{}

      {_, total_kb, available_kb, capacity_percentage} ->
        %{
          disk_total_kb: total_kb,
          disk_available_kb: available_kb,
          disk_used_percentage: capacity_percentage
        }
    end
  end

  defp disk_info(_otp_version) do
    data =
      Enum.find(:disksup.get_disk_data(), fn {key, _, _, _} ->
        key == ~c"/root"
      end)

    case data do
      nil ->
        %{}

      {_, total_kb, capacity_percentage} ->
        %{
          disk_total_kb: total_kb,
          disk_available_kb: capacity_percentage / 100 * total_kb,
          disk_used_percentage: capacity_percentage
        }
    end
  end
end
