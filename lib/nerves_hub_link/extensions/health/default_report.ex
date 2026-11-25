# SPDX-FileCopyrightText: 2024 Jon Carstens
# SPDX-FileCopyrightText: 2024 Lars Wikman
# SPDX-FileCopyrightText: 2025 Elin Olsson
# SPDX-FileCopyrightText: 2025 Josh Kalderimis
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule NervesHubLink.Extensions.Health.DefaultReport do
  @moduledoc """
  The default health report: the metrics `NervesHubLink.Extensions.Metrics` samples, and
  the alarms the device has set.

  Both are configured elsewhere, so there is nothing to configure here. See
  `NervesHubLink.Extensions.Metrics` for the metric sets, and `NervesHubLink.Alarms` for
  how an alarm is named and which ones are left out of a report.
  """
  @behaviour NervesHubLink.Extensions.Health.Report

  alias NervesHubLink.Alarms
  alias NervesHubLink.Extensions.Health.Report
  alias NervesHubLink.Extensions.Metrics

  @impl Report
  def timestamp() do
    DateTime.utc_now()
  end

  @doc """
  The alarm callback will use `Alarmist`, if it is available,
  otherwise it will default to `:alarm_handler`.
  """
  @impl Report
  def alarms() do
    Alarms.get_alarms()
    |> Enum.filter(fn {id, _} -> Alarms.reportable?(id) end)
    |> Enum.into(%{}, fn {id, description} ->
      try do
        {Alarms.name(id), inspect(description)}
      catch
        _, _ ->
          {Alarms.name(id), ""}
      end
    end)
  end

  @impl Report
  def metrics(), do: Metrics.sample()
end
