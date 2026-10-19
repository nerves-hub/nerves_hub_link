# SPDX-FileCopyrightText: 2026 Josh Kalderimis
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule NervesHubLink.Extensions.Alarms do
  @moduledoc """
  The Alarms Extension, version 0.1.0.

  Sends the device's alarms to NervesHub as they are raised and cleared,
  rather than in a health report the next time NervesHub asks for one, which
  can be an hour later. An alarm raised and cleared between two health reports
  is otherwise never seen at all.

  Off by default. To turn it on, name it in `extension_modules` along with the
  other extensions you want, since the list replaces the defaults rather than
  adding to them:

      config :nerves_hub_link,
        extension_modules: [
          NervesHubLink.Extensions.Alarms,
          NervesHubLink.Extensions.Geo,
          NervesHubLink.Extensions.Health,
          NervesHubLink.Extensions.NetworkIdentity
        ]

  Like every extension, it sends nothing until NervesHub asks the device to
  attach it, and NervesHub only asks if the product has the extension enabled.
  While it is attached, `NervesHubLink.Extensions.Health` leaves alarms out of
  its reports, so the two do not both report them.

  ## What is sent

    * When NervesHub attaches the extension, and whenever else it asks
      (`alarms:sync`), every alarm currently set, as `alarms:snapshot`. That is
      what corrects anything that changed while the device was offline.
    * After that, each alarm as it is set (`alarms:raised`) and cleared
      (`alarms:cleared`).

  Alarms are named and filtered as health names and filters them; see
  `NervesHubLink.Alarms.name/1` and `NervesHubLink.Alarms.reportable?/1`.

  ## When

  Each alarm carries the time it was set or cleared. Alarms are watched from
  application start, so an alarm set during boot, before the device had
  connected, is sent with the time it was actually set.

  Times are only sent once `NervesTime.synchronized?/0` says the clock is
  right. Until NTP has synced, the clock is whatever `NervesTime` restored at
  boot, which can be hours or days behind: close enough to pass NervesHub's
  own check on how old a time may be, and still wrong. NervesHub uses the time
  each message arrived instead.

  See the [extensions guide](guides/extensions.md#alarms), and NervesHub's
  `docs/alarms.md` for the protocol.
  """

  use NervesHubLink.Extensions, name: "alarms", version: "0.1.0"

  alias NervesHubLink.Alarms

  require Logger

  @doc """
  Whether the extension is attached, and so whether alarms are being sent
  here rather than in health reports.

  The extension's process only runs while it is attached.
  """
  @spec attached?() :: boolean()
  def attached?(), do: Process.whereis(__MODULE__) != nil

  @impl GenServer
  def init(_opts) do
    # Before anything is sent. NervesHub asks for the whole set once the
    # extension is attached, and anything that changes from here on is then
    # either in that set or sent after it.
    :ok = Alarms.subscribe()
    {:ok, %{}}
  end

  @impl GenServer
  def handle_info(message, state) do
    _ =
      case Alarms.change(message) do
        {:set, id, description, at} ->
          if Alarms.reportable?(id), do: push("raised", raised(id, description, at))

        {:clear, id, _description, at} ->
          if Alarms.reportable?(id),
            do: push("cleared", put_time(%{"alarm" => Alarms.name(id)}, "cleared_at", at))

        :ignore ->
          :ok
      end

    # A push that fails is not retried. NervesHub asks for the whole set again
    # whenever the device reconnects, and that set is what it goes by.
    {:noreply, state}
  end

  @impl NervesHubLink.Extensions
  def handle_event("sync", _payload, state) do
    alarms =
      for {id, description, at} <- Alarms.current_alarms(),
          Alarms.reportable?(id),
          do: raised(id, description, at)

    _ = push("snapshot", %{"alarms" => alarms})

    {:noreply, state}
  end

  def handle_event(event, _payload, state) do
    Logger.debug("[#{inspect(__MODULE__)}] ignoring unknown event: #{inspect(event)}")
    {:noreply, state}
  end

  defp raised(id, description, at) do
    %{"alarm" => Alarms.name(id)}
    |> put_description(description)
    |> put_time("raised_at", at)
  end

  # Health sends every description through `inspect/1`, which puts a string in
  # quotes. A string here is sent as it is, since it is almost always meant to
  # be read.
  defp put_description(payload, nil), do: payload

  defp put_description(payload, description) when is_binary(description),
    do: Map.put(payload, "description", description)

  defp put_description(payload, description) do
    Map.put(payload, "description", inspect(description))
  catch
    _, _ -> payload
  end

  defp put_time(payload, _key, nil), do: payload

  defp put_time(payload, key, at) do
    if clock_synchronized?(),
      do: Map.put(payload, key, at |> Alarms.to_utc() |> DateTime.to_iso8601()),
      else: payload
  end

  defp clock_synchronized?() do
    NervesTime.synchronized?() == true
  catch
    _, _ -> false
  end
end
