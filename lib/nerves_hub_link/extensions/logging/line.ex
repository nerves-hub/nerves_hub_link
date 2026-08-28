# SPDX-FileCopyrightText: 2026 Josh Kalderimis
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule NervesHubLink.Extensions.Logging.Line do
  @moduledoc """
  One log line, in the shape NervesHub stores.

      %{"level" => "info", "message" => "hello", "meta" => %{"time" => "1767..."}}

  ## The timestamp is not optional

  However much the schema's required list suggests otherwise. A line without
  one fails validation on the server and is dropped **silently**: no error back
  to the device, and nothing in the UI. It goes in `meta.time` as microseconds
  since the epoch, written as a string, which is the shape the server parses.

  `:logger` already stamps every event with microseconds since the epoch, so
  the time recorded is when the line was written rather than when the device
  got around to sending it. That distinction is the whole value of a log line
  that spent a minute in a buffer, or an hour of being offline.
  """

  @type t :: %{String.t() => String.t() | %{String.t() => String.t()}}

  @doc """
  Build a line from an OTP log event.
  """
  @spec from_log_event(:logger.log_event()) :: t()
  def from_log_event(%{level: level, msg: msg, meta: meta}) do
    %{
      "level" => to_string(level),
      "message" => message(msg),
      "meta" => %{"time" => timestamp(meta)}
    }
  end

  @doc """
  A line saying how many were dropped, and when the gap opened.

  `at` is the moment the first line was dropped rather than the moment this is
  built, so the server orders the notice ahead of the lines that survived it.
  """
  @spec dropped_notice(pos_integer(), String.t() | nil) :: t()
  def dropped_notice(dropped, at) do
    %{
      "level" => "warning",
      "message" => "nerves_hub_link dropped #{dropped} log lines to stay inside its buffer",
      "meta" => %{"time" => at || now()}
    }
  end

  @doc "Microseconds since the epoch, as the server wants them."
  @spec now() :: String.t()
  def now(), do: to_string(System.os_time(:microsecond))

  defp timestamp(%{time: time}) when is_integer(time), do: to_string(time)
  defp timestamp(_meta), do: now()

  # What `Logger.info("hello")` produces.
  defp message({:string, chardata}), do: to_binary(chardata)

  # OTP reports, which arrive from the runtime rather than from application
  # code: a crash, a supervisor starting a child, an alarm.
  defp message({:report, report}), do: inspect(report)

  defp message({format, args}) when is_list(format) or is_binary(format) do
    format
    |> :io_lib.format(args)
    |> to_binary()
  end

  defp message(other), do: inspect(other)

  defp to_binary(chardata) do
    IO.chardata_to_string(chardata)
  rescue
    # Chardata that will not render is still worth reporting as something.
    _error -> inspect(chardata)
  end
end
