# SPDX-FileCopyrightText: 2025 Josh Kalderimis
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule NervesHubLink.Extensions.Logging.LoggerHandler do
  @moduledoc """
  Send logs to NervesHub.
  """
  if System.otp_release() |> String.to_integer() >= 27 do
    @behaviour :logger_handler
  end

  alias NervesHubLink.Extensions.Logging

  if System.otp_release() |> String.to_integer() >= 27 do
    @impl :logger_handler
    def log(log_event, config)
  end

  # Callback for :logger handlers
  @doc false
  def log(%{msg: {:string, unicode_chardata}} = log_event, _) do
    Logging.send_log_line(log_event.level, unicode_chardata, log_event.meta)
  end

  def log(_, _) do
    # Ignore log events which aren't string log lines
  end
end
