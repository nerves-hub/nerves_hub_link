# SPDX-FileCopyrightText: 2025 Josh Kalderimis
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule NervesHubLink.Extensions.Logging do
  @moduledoc """
  The Logging Extension.

  Send logs to NervesHub for easy debugging.

  This extension is disabled by default while in Early Release.
  """
  use NervesHubLink.Extensions, name: "logging", version: "0.0.1"

  require Logger

  @doc """
  Request a log payload be sent asynchronously.

  ## Examples

      iex> NervesHubLink.Extensions.Logging.send_logs(:info, "hello, it's me", %{sensor: "door lock"})
      :ok

  """
  @spec send_log_line(atom(), String.t(), map()) :: :ok
  def send_log_line(level, message, meta) do
    formatted = for {k, v} <- meta, into: %{}, do: {k, inspect(v)}
    GenServer.cast(__MODULE__, {:send_logs, %{level: level, message: message, meta: formatted}})
  end

  @impl GenServer
  def init(_opts) do
    _ =
      :logger.add_handler(
        :nerves_hub_link_logger_extension_handler,
        NervesHubLink.Extensions.Logging.LoggerHandler,
        %{}
      )

    {:ok, %{}}
  end

  @impl NervesHubLink.Extensions
  def handle_event(_, _msg, state) do
    {:noreply, state}
  end

  @impl GenServer
  def handle_cast({:send_logs, log_payload}, state) do
    _ = push("send", log_payload)
    {:noreply, state}
  end
end
