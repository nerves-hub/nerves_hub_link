# SPDX-FileCopyrightText: 2026 Josh Kalderimis
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule NervesHubLink.Extensions.Logging.Handler do
  @moduledoc """
  The `:logger` handler that feeds
  `NervesHubLink.Extensions.Logging.Collector`.

  Runs in whichever process is doing the logging, so it does as little as it
  can: shape the line, send it, return. It never calls the collector and never
  logs, because a handler that waits charges the application for the reporting
  and a handler that logs never stops.

  `:logger` applies the handler's level before this is called, so a line below
  the configured level costs nothing at all.
  """

  alias NervesHubLink.Extensions.Logging.Collector
  alias NervesHubLink.Extensions.Logging.Line

  @doc false
  @spec log(:logger.log_event(), :logger.handler_config()) :: :ok
  def log(event, _config) do
    Collector.collect(Line.from_log_event(event))
  rescue
    # A device that cannot report a line should still run. Raising here would
    # take out whatever process happened to be logging, which is any process at
    # all.
    _error -> :ok
  end
end
