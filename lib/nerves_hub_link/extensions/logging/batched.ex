# SPDX-FileCopyrightText: 2026 Josh Kalderimis
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule NervesHubLink.Extensions.Logging.Batched do
  @moduledoc """
  The Logging Extension, version 0.1.0.

  Sends the device's log lines to NervesHub, where they are stored against the
  device and made searchable. One direction only: nothing is ever sent back.

  `NervesHubLink.Extensions.Logging` is version 0.0.1 of the same extension and
  lives alongside this one. They are the same feature and a device offers
  whichever the platform has, so naming both in `extension_modules` is what
  gets a device the better one where it is available:

      config :nerves_hub_link,
        extension_modules: [
          NervesHubLink.Extensions.Geo,
          NervesHubLink.Extensions.Health,
          NervesHubLink.Extensions.LocalShell,
          NervesHubLink.Extensions.NetworkIdentity,
          NervesHubLink.Extensions.Logging,
          NervesHubLink.Extensions.Logging.Batched
        ]

  ## What 0.1.0 changes

  0.0.1 sends a message per line. NervesHub limits how often a device may send
  rather than how much it may say, so that is a limit on lines: a device in a
  crash loop loses almost everything it writes, and the survivors are an
  arbitrary sample rather than the part worth reading.

  This version collects lines in
  `NervesHubLink.Extensions.Logging.Collector` and sends a minute of them at a
  time, in messages of up to a hundred lines. The same send budget then carries
  a minute of logs rather than a handful of lines.

  The collector also runs from application start rather than from the attach,
  so what a device writes while booting, while offline, or while NervesHub is
  deciding whether it wants logging at all is still there to send.

  ## Configuration

      config :nerves_hub_link,
        logging: [
          level: :info,
          max_lines: 1000,
          interval_seconds: 60
        ]

  `level` is shared with 0.0.1. `max_lines` is how many lines the collector
  holds before dropping the oldest, and `interval_seconds` is never less than
  60 whatever it is set to.
  """

  use NervesHubLink.Extensions,
    name: "logging",
    version: "0.1.0",
    versions: [NervesHubLink.Extensions.Logging, NervesHubLink.Extensions.Logging.Batched]

  alias NervesHubLink.Extensions.Logging.Collector
  alias NervesHubLink.Extensions.Logging.Config

  require Logger

  # The platform's cap on one message. Sending more loses the excess
  # server-side, so a flush goes out in chunks of this. Not configurable:
  # it is NervesHub's number, not this device's.
  @max_lines_per_message 100

  @doc """
  Send whatever has collected, without waiting for the next flush.

  ## Examples

      iex> NervesHubLink.Extensions.Logging.flush()
      :ok

  """
  @spec flush() :: :ok
  def flush(), do: GenServer.cast(__MODULE__, :flush)

  @impl GenServer
  def init(_opts) do
    {:ok, %{}, {:continue, :schedule}}
  end

  @impl GenServer
  def handle_continue(:schedule, state) do
    {:noreply, schedule(state)}
  end

  @impl GenServer
  def handle_cast(:flush, state) do
    {:noreply, send_lines(state)}
  end

  @impl GenServer
  def handle_info(:flush, state) do
    {:noreply, state |> send_lines() |> schedule()}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl NervesHubLink.Extensions
  def handle_event(event, _payload, state) do
    # Nothing is asked of this extension, so anything arriving is a NervesHub
    # that knows something this device does not.
    Logger.debug("[#{inspect(__MODULE__)}] ignoring unknown event: #{inspect(event)}")

    {:noreply, state}
  end

  defp schedule(state) do
    _ = Process.send_after(self(), :flush, Config.interval())

    state
  end

  # In chunks, because the platform drops whatever one message carries past its
  # cap. Each chunk is dropped from the collector only once it has gone, so a
  # socket that dies part way through a flush leaves the rest for the next one.
  defp send_lines(state) do
    case Collector.take(@max_lines_per_message) do
      [] ->
        state

      lines ->
        case push("send", %{"lines" => lines}) do
          {:ok, _ref} ->
            :ok = Collector.sent(length(lines))
            send_lines(state)

          {:error, _reason} ->
            state
        end
    end
  end
end
