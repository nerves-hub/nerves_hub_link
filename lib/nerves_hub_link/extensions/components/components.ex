# SPDX-FileCopyrightText: 2026 Josh Kalderimis
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule NervesHubLink.Extensions.Components do
  @moduledoc """
  The Components Extension, version 0.1.0.

  Reports the things the device is connected to: a microcontroller on a UART,
  Zigbee and Z-Wave nodes paired to its radio, a USB peripheral. NervesHub
  calls each of these a **component**, lists them on the device's Components
  tab, and groups them by model on the product's Components page.

  Off by default. To turn it on, name it in `extension_modules` along with the
  other extensions you want, since the list replaces the defaults rather than
  adding to them:

      config :nerves_hub_link,
        extension_modules: [
          NervesHubLink.Extensions.Components,
          NervesHubLink.Extensions.Geo,
          NervesHubLink.Extensions.Health,
          NervesHubLink.Extensions.NetworkIdentity
        ]

  Like every extension, it sends nothing until NervesHub asks the device to
  attach it, and NervesHub only asks if the product has the extension enabled.

  ## Telling NervesHub what the device has

  NervesHubLink can't find your components: your application knows what is on
  its buses and radios. It can answer when NervesHub asks, from its
  `NervesHubLink.Client` (see [Answering NervesHub](#module-answering-nerveshub)),
  or tell this extension whenever they change:

      NervesHubLink.Extensions.Components.set_components([
        %{
          namespace: "mcu",
          vendor: "raspberrypi",
          model: "rp2350",
          serial: "e6614c311b4a2c2f",
          name: "Power controller",
          address: "UART0",
          versions: %{firmware: "1.4.2"}
        },
        %{
          namespace: "zigbee",
          vendor: "1286",
          model: "SNZB-02D",
          serial: "00:12:4b:00:2a:3f:91:c7",
          name: "Freezer probe A",
          vendor_name: "Sonoff"
        }
      ])

  NervesHub is always sent the **whole set**, never a change to it. A set
  can't drift the way a stream of events can, so there is no event for a
  component going away: it is simply no longer in the set. Tell the extension
  the set whenever it changes, or change one component at a time with
  `put_component/1` and `delete_component/2`. A component the device still has
  but can't reach stays in the set, with `reachable: false`.

  See `NervesHubLink.Extensions.Components.Component` for every field.

  ## When the set is sent

    * When NervesHub asks, which it does as soon as the extension attaches.
    * Five seconds after the set last changed, so that pairing twenty sensors
      in a row sends one snapshot rather than twenty. A set that keeps changing
      is still sent at least every thirty seconds.

  Call `set_components/1` as often as you like. A set that comes out the same
  as the one NervesHub already has is not sent again.

  ## Namespaces, and what `vendor`, `model` and `serial` mean

  The namespace says what kind of component it is and how to read the other
  three. These have a convention, and should be used as written whenever a
  component fits one:

  | Namespace | `vendor` | `model` | `serial` |
  | --- | --- | --- | --- |
  | `mcu` | The chip maker, lower case: `raspberrypi`, `st` | The part, lower case: `rp2350` | The chip's unique ID, lower case hex |
  | `zigbee` | Manufacturer code, 4 hex digits | The Basic cluster's model identifier: `SNZB-02D` | IEEE address, `00:12:4b:00:2a:3f:91:c7` |
  | `zwave` | Manufacturer ID, 4 hex digits | Product type and product ID, `8002:0600` | The node's DSK, or `homeid:nodeid` for a node without one |
  | `ble` | Bluetooth SIG company identifier, 4 hex digits | Yours | The device address, `c4:5b:be:01:22:9f` |
  | `usb` | Vendor ID, 4 hex digits | Product ID, 4 hex digits | The serial number string, or `address` when it has none |
  | `custom` | Yours | Yours | Yours |

  Hex is lower case with no `0x`. Any other namespace of lower case letters,
  digits and `_` is accepted, but use `custom` until a convention is agreed.

  `serial` is required, even for a component without a serial number, because
  it is how NervesHub tells one component from the next. Send the first of
  these it has: a hardware ID; where it is on the device (`i2c-1:76`, a USB
  port path); your application's own name for it (`freezer-probe-a`); or the
  model, if the device can only ever have one. Never send something that
  changes on its own, like a list index or `ttyUSB0`: a component sent under a
  new `serial` is a new component, and the old one shows as Missing.

  ## Readings and state

  A component can also report numbers it measures, with `report_readings/4`,
  and named states that change now and then, such as a lock being `locked` or
  `unlocked`, with `report_state/5`:

      alias NervesHubLink.Extensions.Components

      Components.report_readings("zigbee", "00:12:4b:00:2a:3f:91:c7", %{temperature: -18.9, battery: 87})

      Components.report_state("zwave", lock_dsk, :lock, :unlocked, detail: "by keypad, user 3")

  Both are only accepted for a component in the set. Readings are collected
  and sent at most once a second, many to a message. A state change is sent
  straight away, and the device also remembers it: every snapshot carries each
  component's current state, so a change NervesHub missed is put right by the
  next one.

  ## Answering NervesHub

  NervesHub asks for the set every time the device connects, and again when
  someone in the web UI asks the device to look at its components again. Each
  time, the device asks its `NervesHubLink.Client` first, through
  `c:NervesHubLink.Client.components_sync/1`, and answers with what it
  returns. So a device can report its components from its client and never
  call `set_components/1` at all:

      defmodule MyApp.NervesHubLinkClient do
        use NervesHubLink.Client

        @impl NervesHubLink.Client
        def components_sync(_opts) do
          {:ok, MyApp.Hardware.components()}
        end
      end

  The default returns `:ok`, which answers with the set as it stands: whatever
  `set_components/1` and `put_component/1` were last given, or no components
  if nothing was. Changes pushed that way still go out within five seconds,
  rather than waiting for NervesHub to ask.

  The client can be swapped for a module or an MFA with `refresher`; see
  `NervesHubLink.Extensions.Components.Refresher`.

  ## Configuration

      config :nerves_hub_link,
        components: [
          # The client by default; or a module, or {module, function, args}.
          refresher: MyApp.ComponentRefresher,
          refresh_timeout_seconds: 30,
          # How many readings to hold while they can't be sent.
          max_readings: 600
        ]

  ## Bad entries

  NervesHub rejects a whole snapshot when anything in it is wrong. So every
  component, reading and state change is checked on the device first, against
  the rules NervesHub applies, and a bad one is logged and left out rather
  than sent. A mistake in one component costs that component and no others.
  """

  use NervesHubLink.Extensions, name: "components", version: "0.1.0"

  alias NervesHubLink.Extensions.Components.Component
  alias NervesHubLink.Extensions.Components.Config
  alias NervesHubLink.Extensions.Components.Reading
  alias NervesHubLink.Extensions.Components.StateChange
  alias NervesHubLink.Extensions.Components.Store

  require Logger

  @typedoc """
  Why a call was refused.

    * a string - the component, reading or state change isn't one NervesHub
      would accept, and says why.
    * `:unknown_component` - the component isn't in the set.
    * `:too_many_components` - the set already has the 500 components
      NervesHub accepts.
    * `:too_many_states` - the component already has the 8 states NervesHub
      keeps.
    * `:not_running` - the extension isn't configured, or NervesHubLink hasn't
      started yet. Nothing was recorded.
  """
  @type error() ::
          String.t()
          | :unknown_component
          | :too_many_components
          | :too_many_states
          | :not_running

  @doc """
  Replace the device's whole component set.

  Every component the device has, reachable or not. An empty list says it has
  none. The set is sent to NervesHub five seconds after the last change to it,
  or straight away if NervesHub asks first.

  A component that isn't valid, or shares its `namespace` and `serial` with
  one listed before it, is logged and left out, and the rest are set.
  NervesHub accepts at most #{Store.max_components()} components, so any past
  that are logged and left out too.

  A component listed without `state` keeps any state the device has reported
  for it. See `NervesHubLink.Extensions.Components.Component` for the fields.

  Returns `{:error, :not_running}`, and records nothing, when the extension
  isn't configured or NervesHubLink hasn't started.
  """
  @spec set_components([Component.input()]) :: :ok | {:error, :not_running}
  def set_components(components) when is_list(components) do
    components |> checked() |> Store.set()
  end

  @doc """
  Add a component to the set, or replace the one with the same `namespace` and
  `serial`.

  For an application that hears about components one at a time, such as a
  Zigbee coordinator announcing a node that has joined.
  """
  @spec put_component(Component.input()) :: :ok | {:error, error()}
  def put_component(component) do
    case Component.new(component) do
      {:ok, entry} -> Store.put(entry)
      {:error, reason} -> rejected(component, reason)
    end
  end

  @doc """
  Remove a component from the set.

  Only for a component the device no longer has. One it has but can't reach
  belongs in the set with `reachable: false`, which NervesHub shows as "can't
  reach it" rather than "stopped listing it".
  """
  @spec delete_component(String.t() | atom(), String.t()) :: :ok | {:error, :not_running}
  def delete_component(namespace, serial) do
    Store.delete({to_string(namespace), serial})
  end

  @doc """
  The component set as it would be sent to NervesHub now, with each
  component's state.

  For a console, when a device isn't showing what you expect.
  """
  @spec components() :: [Component.t()]
  def components(), do: Store.components()

  @doc """
  Report numbers a component measured.

      report_readings("zigbee", "00:12:4b:00:2a:3f:91:c7", %{temperature: -18.9, battery: 87})

  Names are lower case letters, digits and `_`, starting with a letter, at most
  64 characters, and values are numbers. Use the same name for the same
  quantity on every model: `temperature` in degrees Celsius, `humidity` and
  `battery` in percent, `co2` in ppm.

  A reading with a name or value NervesHub would refuse is dropped and logged,
  and the rest are reported. NervesHub keeps 20 readings a report, so past
  that only the first 20 by name are sent.

  Readings for a component that isn't in the set are logged and dropped.

  Readings are collected and sent together, at most one message a second, so
  report them as they are measured. They are held while the device is offline,
  up to `max_readings`, and the oldest are dropped past that.

  ## Options

    * `:timestamp` - when they were measured, as a `DateTime`. Defaults to now.
      NervesHub skips a report more than 24 hours from its own clock.
  """
  @spec report_readings(String.t() | atom(), String.t(), map(), keyword()) ::
          :ok | {:error, error()}
  def report_readings(namespace, serial, readings, opts \\ []) do
    case Reading.new(namespace, serial, readings, opts) do
      {:ok, report} ->
        # Checked here rather than left to the cast, which would say `:ok` to
        # a store that isn't there.
        if Process.whereis(Store), do: Store.readings(report), else: {:error, :not_running}

      {:error, _reason} = error ->
        error
    end
  end

  @doc """
  Report that one of a component's states has a new value.

      report_state("zwave", lock_dsk, :lock, :unlocked, detail: "by keypad, user 3")

  `state` is lower case letters, digits and `_`, starting with a letter, at
  most 64 characters. `value` is a string of at most 64 characters. Either can
  be an atom. A component has at most 8 states.

  Sent straight away, and remembered: every snapshot carries the component's
  current state, so a change NervesHub missed, because the device was offline
  or it was rate limited, is put right by the next snapshot. Reporting the
  value a state already has sends nothing.

  A snapshot carries every state the device has reported for a component since
  it started, and NervesHub replaces what it has with that. So report all of a
  component's states when the device starts, or give them in the component's
  `state` field, or the first snapshot after a reboot leaves out the ones you
  haven't reported yet.

  ## Options

    * `:detail` - who or what changed it, shown beside the change: `"by keypad,
      user 3"`. At most 255 characters.
    * `:changed_at` - when it changed, as a `DateTime`. Defaults to now. Pass
      `nil` on a device without a clock it can trust, and NervesHub uses the
      time the change arrived.
  """
  @spec report_state(
          String.t() | atom(),
          String.t(),
          String.t() | atom(),
          String.t() | atom(),
          keyword()
        ) ::
          :ok | {:error, error()}
  def report_state(namespace, serial, state, value, opts \\ []) do
    case StateChange.new(namespace, serial, state, value, opts) do
      {:ok, frame} -> Store.state(frame)
      {:error, _reason} = error -> error
    end
  end

  @impl GenServer
  def init(_opts) do
    # So `terminate/2` runs when the extension is detached, and can stop a
    # refresher that would otherwise outlive it.
    Process.flag(:trap_exit, true)

    # Nothing is sent on start. NervesHub sends `components:sync` when it
    # attaches the extension, and the answer is the first snapshot.
    #
    # `again` is a sync that arrived while the refresher was running for one
    # that it doesn't answer: a refresh asked for while a plain sync's
    # refresher, which won't check, was already running.
    {:ok, %{refresh: nil, again: nil}}
  end

  @impl GenServer
  def terminate(_reason, %{refresh: %{pid: pid}}) do
    Process.exit(pid, :kill)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  @impl NervesHubLink.Extensions
  def handle_event("sync", payload, state) do
    {:noreply, start_refresh(state, refresh?(payload))}
  end

  def handle_event(event, _payload, state) do
    # Only `sync` is sent to the device, so anything else is a NervesHub that
    # knows something this device does not.
    Logger.debug("[#{inspect(__MODULE__)}] ignoring unknown event: #{inspect(event)}")

    {:noreply, state}
  end

  @impl GenServer
  def handle_info({:refreshed, pid, result}, %{refresh: %{pid: pid}} = state) do
    _ = apply_refresh(result, state.refresh.refresher)
    {:noreply, finish_refresh(state)}
  end

  def handle_info(
        {:DOWN, monitor, :process, _pid, reason},
        %{refresh: %{monitor: monitor}} = state
      ) do
    Logger.warning(
      "[#{inspect(__MODULE__)}] #{describe(state.refresh.refresher)} failed: " <>
        Exception.format_exit(reason) <> "; answering with the set as it stands"
    )

    {:noreply, finish_refresh(state)}
  end

  def handle_info({:refresh_timeout, pid}, %{refresh: %{pid: pid}} = state) do
    Process.exit(pid, :kill)

    Logger.warning(
      "[#{inspect(__MODULE__)}] #{describe(state.refresh.refresher)} took too long; " <>
        "answering with the set as it stands"
    )

    {:noreply, finish_refresh(state)}
  end

  # A refresher's result or timeout that arrived after it was finished with,
  # or the exit of a process this one was linked to.
  def handle_info(_message, state), do: {:noreply, state}

  defp refresh?(%{"refresh" => true}), do: true
  defp refresh?(_payload), do: false

  # In a process of its own, so a slow refresher holds up nothing but the
  # answer. Monitored rather than linked: one that crashes costs that answer,
  # not the extension.
  defp start_refresh(%{refresh: nil} = state, refresh?) do
    refresher = Config.refresher()
    opts = [refresh: refresh?]
    parent = self()

    {pid, monitor} =
      spawn_monitor(fn -> send(parent, {:refreshed, self(), call(refresher, opts)}) end)

    timer = Process.send_after(self(), {:refresh_timeout, pid}, Config.refresh_timeout())

    running = %{
      pid: pid,
      monitor: monitor,
      timer: timer,
      refresher: refresher,
      refresh?: refresh?
    }

    %{state | refresh: running, again: nil}
  end

  # The one already running answers this sync too, unless this one asks the
  # device to look again and that one won't. Then it runs again once that one
  # has answered.
  defp start_refresh(%{refresh: %{refresh?: false}} = state, true), do: %{state | again: true}
  defp start_refresh(state, _refresh?), do: state

  defp call(:client, opts), do: NervesHubLink.Client.components_sync(opts)
  defp call({module, function, args}, opts), do: apply(module, function, args ++ [opts])
  defp call(module, opts), do: module.refresh(opts)

  defp describe(:client), do: "#{inspect(NervesHubLink.Client)}.components_sync/1"

  defp describe({module, function, args}),
    do: "#{inspect(module)}.#{function}/#{length(args) + 1}"

  defp describe(module), do: "#{inspect(module)}.refresh/1"

  defp apply_refresh(:ok, _refresher), do: :ok

  defp apply_refresh({:ok, components}, _refresher) when is_list(components),
    do: set_components(components)

  # `NervesHubLink.Client` turns a raise or exit in the client into these, and
  # has already logged it.
  defp apply_refresh({:exit, _reason}, _refresher), do: :ok

  defp apply_refresh({:error, reason}, refresher) do
    Logger.warning(
      "[#{inspect(__MODULE__)}] #{describe(refresher)} couldn't list components: #{inspect(reason)}; " <>
        "answering with the set as it stands"
    )
  end

  defp apply_refresh(other, refresher) do
    Logger.warning(
      "[#{inspect(__MODULE__)}] #{describe(refresher)} returned #{inspect(other, limit: 5)}, " <>
        "expected :ok, {:ok, components} or {:error, reason}"
    )
  end

  # Answered whatever happened: NervesHub asked, and a device must answer
  # every sync with a snapshot.
  defp finish_refresh(%{refresh: refresh} = state) do
    Process.demonitor(refresh.monitor, [:flush])
    _ = Process.cancel_timer(refresh.timer)
    :ok = Store.answer_sync()

    case state.again do
      nil -> %{state | refresh: nil}
      refresh? -> start_refresh(%{state | refresh: nil}, refresh?)
    end
  end

  defp checked(components) do
    {entries, _seen} =
      Enum.reduce(components, {[], MapSet.new()}, fn component, acc ->
        case Component.new(component) do
          {:ok, entry} ->
            add_unique(entry, acc)

          {:error, reason} ->
            _ = rejected(component, reason)
            acc
        end
      end)

    entries = Enum.reverse(entries)
    max = Store.max_components()

    if length(entries) > max do
      Logger.error(
        "[#{inspect(__MODULE__)}] the set has #{length(entries)} components and NervesHub accepts #{max}; " <>
          "left out the last #{length(entries) - max}"
      )
    end

    Enum.take(entries, max)
  end

  # NervesHub rejects a snapshot listing the same component twice, and the
  # first one listed is as likely to be right as the second.
  defp add_unique(entry, {entries, seen}) do
    key = Component.key(entry)

    if MapSet.member?(seen, key) do
      {namespace, serial} = key

      Logger.warning(
        "[#{inspect(__MODULE__)}] left out #{namespace} #{serial}: it is listed more than once"
      )

      {entries, seen}
    else
      {[entry | entries], MapSet.put(seen, key)}
    end
  end

  defp rejected(component, reason) do
    Logger.warning(
      "[#{inspect(__MODULE__)}] left out a component: #{reason}: #{inspect(component, limit: 10)}"
    )

    {:error, reason}
  end
end
