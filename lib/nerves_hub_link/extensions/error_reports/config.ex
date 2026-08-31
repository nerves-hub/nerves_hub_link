# SPDX-FileCopyrightText: 2026 Josh Kalderimis
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule NervesHubLink.Extensions.ErrorReports.Config do
  @moduledoc """
  How the Error Reports extension is configured.

      config :nerves_hub_link,
        error_reports: [
          max_reports: 100,
          interval_seconds: 60,
          context: {MyApp.Telemetry, :error_context, []}
        ]

  Turning error reports on is naming the module in `extension_modules`, not a
  key here.
  """

  # Four messages' worth. The platform caps a message at 25 reports and allows
  # a burst of five, so this is a little under what one flush can deliver, and
  # a device holding more than a hundred distinct crashes has bigger problems
  # than the ones it cannot report.
  @default_max_reports 100

  # The floor as well as the default. A shorter interval spends the device's
  # send budget on smaller batches without getting more reports through.
  @default_interval_seconds 60

  @doc "How many reports to hold before dropping the oldest."
  @spec max_reports() :: pos_integer()
  def max_reports(), do: Keyword.get(config(), :max_reports, @default_max_reports)

  @doc """
  How long to buffer before sending, in milliseconds.

  Never less than #{@default_interval_seconds} seconds, whatever is configured.
  """
  @spec interval() :: pos_integer()
  def interval() do
    config()
    |> Keyword.get(:interval_seconds, @default_interval_seconds)
    |> max(@default_interval_seconds)
    |> :timer.seconds()
  end

  @doc """
  Device state to attach to every report, as a string map.

  Uptime by default, because it is the one thing every runtime can answer
  cheaply. Anything else is device-specific, and reading it is not free: the
  health extension shells out to `free` for memory, which is not something to
  do in the middle of a crash.

  So the rest is yours to supply. Point `:context` at a function returning a
  map and it is merged over the default:

      config :nerves_hub_link,
        error_reports: [context: {MyApp.Telemetry, :error_context, []}]

      def error_context() do
        %{"reboot_count" => Nerves.Runtime.KV.get("nerves_fw_validated"), "site" => "depot-4"}
      end

  Keys named `uptime_ms`, `free_memory_bytes` and `reboot_count` are given
  units in the NervesHub UI. Everything else is shown as it arrives.

  Called on the extension's own process when a batch is sent, never in the
  process that crashed. A function that raises costs the report its context and
  nothing else.
  """
  @spec context() :: %{String.t() => String.t()}
  def context() do
    Map.merge(default_context(), configured_context())
  end

  defp default_context() do
    %{"uptime_ms" => to_string(elem(:erlang.statistics(:wall_clock), 0))}
  end

  defp configured_context() do
    case Keyword.get(config(), :context) do
      {module, function, args} -> stringify(apply(module, function, args))
      function when is_function(function, 0) -> stringify(function.())
      _not_configured -> %{}
    end
  rescue
    _error -> %{}
  end

  defp stringify(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), stringify_value(value)} end)
  end

  defp stringify(_other), do: %{}

  defp stringify_value(value) when is_binary(value), do: value
  defp stringify_value(value) when is_number(value) or is_atom(value), do: to_string(value)
  defp stringify_value(value), do: inspect(value)

  defp config(), do: Application.get_env(:nerves_hub_link, :error_reports, [])
end
