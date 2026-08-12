# SPDX-FileCopyrightText: 2025 Josh Kalderimis
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule NervesHubLink.Extensions.Logging do
  @moduledoc """
  The Logging Extension.

  Send logs to NervesHub for easy debugging.

  This extension is in early release and is off by default. To turn it on, name
  it in `extension_modules`, along with the other extensions you want — the list
  replaces the defaults rather than adding to them:

      config :nerves_hub_link,
        extension_modules: [
          NervesHubLink.Extensions.Geo,
          NervesHubLink.Extensions.Health,
          NervesHubLink.Extensions.LocalShell,
          NervesHubLink.Extensions.Logging
        ]

  Like every extension, it sends nothing until NervesHub asks the device to
  attach it.

  Every log line is a message over the socket, so only `:info` and above are sent
  by default. Devices on metered connections will want to raise that:

      config :nerves_hub_link,
        logging: [level: :warning]

  Any [Logger level](`t:Logger.level/0`) is accepted, as is `:all` to send
  everything the `Logger` level allows through.
  """
  use NervesHubLink.Extensions, name: "logging", version: "0.0.1"

  alias NervesHubLink.Extensions.Logging.LoggerHandler

  @handler_id :nerves_hub_link_logger_extension_handler

  @default_level :info

  @doc """
  Request a log payload be sent asynchronously.

  ## Examples

      iex> NervesHubLink.Extensions.Logging.send_log_line(:info, "hello, it's me", %{sensor: "door lock"})
      :ok

  """
  @spec send_log_line(atom(), IO.chardata(), map()) :: :ok
  def send_log_line(level, message, meta) do
    # Deliberately no work here: this runs in whichever process called `Logger`,
    # so formatting the line would put the cost of logging to NervesHub on
    # application code, whether or not the line ends up being sent.
    GenServer.cast(__MODULE__, {:send_logs, level, message, meta})
  end

  @impl GenServer
  def init(_opts) do
    # Needed so `terminate/2` runs when the extension is detached, otherwise the
    # handler outlives the process that installed it.
    Process.flag(:trap_exit, true)

    _ = :logger.add_handler(@handler_id, LoggerHandler, %{level: level()})

    {:ok, %{}}
  end

  @impl GenServer
  def terminate(_reason, _state) do
    _ = :logger.remove_handler(@handler_id)
    :ok
  end

  @impl NervesHubLink.Extensions
  def handle_event(_, _msg, state) do
    {:noreply, state}
  end

  @impl GenServer
  def handle_cast({:send_logs, level, message, meta}, state) do
    payload = %{
      level: level,
      message: to_message(message),
      meta: for({k, v} <- meta, into: %{}, do: {k, inspect(v)})
    }

    _ = push_log(payload)

    {:noreply, state}
  end

  defp level() do
    Application.get_env(:nerves_hub_link, :logging, [])
    |> Keyword.get(:level, @default_level)
  end

  # `Logger` hands over chardata, which is often an iolist rather than a binary.
  # Sending that as-is puts an array of fragments on the wire instead of a line
  # of text.
  defp to_message(chardata) do
    IO.chardata_to_string(chardata)
  rescue
    _ -> inspect(chardata)
  end

  # Logs are the least important thing on this socket. Losing the extension
  # because a push timed out would also lose the handler that feeds it, so
  # failures are dropped rather than raised.
  defp push_log(payload) do
    push("send", payload)
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end
end
