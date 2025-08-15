# SPDX-FileCopyrightText: 2025 Josh Kalderimis
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule NervesHubLink.Alarms do
  @moduledoc """
  A slim adapter for `Alarmist` and `:alarm_handler`, providing a unified interface for setting and clearing alarms.
  """

  if Code.ensure_loaded?(Alarmist) do
    @spec get_alarms() :: [{term(), term()}]
    def get_alarms(), do: Alarmist.get_alarms()

    @spec clear_alarm(term()) :: :ok
    def clear_alarm(alarm), do: :alarm_handler.clear_alarm(alarm)

    @spec set_alarm({term(), term()}) :: :ok
    def set_alarm(alarm), do: :alarm_handler.set_alarm(alarm)
  else
    @spec get_alarms() :: [{term(), term()}]
    def get_alarms(), do: :alarm_handler.get_alarms()

    @spec clear_alarm(term()) :: :ok
    def clear_alarm(alarm) do
      get_alarms()
      |> Enum.filter(&(elem(&1, 0) == alarm))
      |> Enum.each(fn _ -> :alarm_handler.clear_alarm(alarm) end)

      :ok
    end

    @spec set_alarm({term(), term()}) :: :ok
    def set_alarm({mod, _} = alarm) do
      if Enum.any?(:alarm_handler.get_alarms(), &(elem(&1, 0) == mod)) do
        :ok
      else
        :alarm_handler.set_alarm(alarm)
      end
    end
  end
end
