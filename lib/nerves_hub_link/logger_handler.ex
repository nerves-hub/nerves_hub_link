defmodule NervesHubLink.Utils.LoggerHandler do
  @moduledoc """
  Send logs to NervesHub.
  """

  alias NervesHubLink.Extensions.Logging

  # Callback for :logger handlers
  @doc false
  @spec log(:logger.log_event(), :logger.handler_config()) :: :ok
  def log(%{msg: {:string, unicode_chardata}} = log_event, _) do
    Logging.send_log_line(log_event.level, unicode_chardata, log_event.meta)
    :ok
  end

  def log(_, _) do
    # Ignore log events which aren't string log lines
  end
end
