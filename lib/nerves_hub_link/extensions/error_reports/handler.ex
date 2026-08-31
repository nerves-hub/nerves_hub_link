# SPDX-FileCopyrightText: 2026 Josh Kalderimis
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule NervesHubLink.Extensions.ErrorReports.Handler do
  @moduledoc """
  The `:logger` handler that feeds
  `NervesHubLink.Extensions.ErrorReports.Collector`.

  ## What it picks up

  Log events carrying `crash_reason` metadata, and nothing else. That is what
  the runtime attaches when a process dies with an exception, an exit or a
  throw: `proc_lib` crash reports, GenServer terminations, failed tasks. It is
  also what `Logger.error(msg, crash_reason: {exception, stacktrace})` sets, so
  application code that wants to report by hand already has a way in.

  Keying on `crash_reason` rather than on the level is deliberate. An error is
  not every line logged at `:error` — most of those are text, with nothing to
  build a stacktrace or a fingerprint from — and it is not only the ones OTP
  labels as crash reports either.

  Runs in whichever process is doing the logging, so it does as little as it
  can and never logs. A handler that waits charges the application for the
  reporting, and a handler that logs never stops.
  """

  alias NervesHubLink.Extensions.ErrorReports.Collector
  alias NervesHubLink.Extensions.ErrorReports.Report

  @doc false
  @spec log(:logger.log_event(), :logger.handler_config()) :: :ok
  def log(event, _config) do
    case Report.from_log_event(event) do
      nil -> :ok
      report -> Collector.collect(report)
    end
  rescue
    # The process that raised here is whichever one was already crashing. A
    # device that cannot report an error should still run.
    _error -> :ok
  end
end
