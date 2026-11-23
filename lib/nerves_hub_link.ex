# SPDX-FileCopyrightText: 2019 Jon Carstens
# SPDX-FileCopyrightText: 2020 Justin Schneck
# SPDX-FileCopyrightText: 2023 Eric Oestrich
# SPDX-FileCopyrightText: 2023 Frank Hunleth
# SPDX-FileCopyrightText: 2024 Lars Wikman
# SPDX-FileCopyrightText: 2025 Josh Kalderimis
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule NervesHubLink do
  @moduledoc """
  The Device-side client for NervesHub.

  The `:nerves_hub_link` Erlang application will start by default if installed
  as a dependency and use provided configuration to connect to a NervesHub
  server.

  This module primarily provides utility functions for checking the status of
  the connection and performing some operations such as reconnecting, sending
  a file to a connected console and more.
  """

  alias NervesHubLink.Extensions.ErrorReports
  alias NervesHubLink.Socket
  alias NervesHubLink.UpdateManager

  @typedoc """
  How a device receives firmware.

  `:automatic` is the default — the device's deployment group sends firmware on
  its own schedule. `:device_managed` means the device asks for firmware itself,
  on whatever schedule suits it; its deployment group still decides *which*
  firmware. `:off` means it takes none but a manual push from an operator.
  """
  @type update_mode :: :off | :automatic | :device_managed

  @typedoc """
  An option to `going_to_sleep/2`.
  """
  @type sleep_option :: {:mode, :deep | :light} | {:duration_ms, pos_integer() | nil}

  @type update_status ::
          :received
          | {:started, downloader_network_interface :: String.t() | nil}
          | {:downloading, non_neg_integer()}
          | {:updating, non_neg_integer()}
          | :completed
          | {:ignored, reason :: String.t()}
          | {:reschedule, delay_for :: pos_integer()}
          | {:reschedule, delay_for :: pos_integer(), reason :: String.t()}
          | {:failed, reason :: String.t()}

  @doc """
  Checks if the device is connected to the NervesHub device channel.
  """
  @spec connected?(GenServer.server()) :: boolean()
  def connected?(server \\ Socket) do
    Socket.check_connection(server, :device)
  end

  @doc """
  Checks if the device is connected to the NervesHub console channel.
  """
  @spec console_connected?(GenServer.server()) :: boolean()
  def console_connected?(server \\ Socket) do
    Socket.check_connection(server, :console)
  end

  @doc """
  Checks if the device is connected to the NervesHub extensions channel.
  """
  @spec extensions_connected?(GenServer.server()) :: boolean()
  def extensions_connected?(server \\ Socket) do
    Socket.check_connection(server, :extensions)
  end

  @doc """
  Checks if the device has a socket connection with NervesHub
  """
  @spec socket_connected?(GenServer.server()) :: boolean()
  def socket_connected?(server \\ Socket) do
    Socket.check_connection(server, :socket)
  end

  @doc """
  Return whether there's currently an active console session
  """
  @spec console_active?(GenServer.server()) :: boolean()
  defdelegate console_active?(server \\ Socket), to: Socket

  @doc """
  Current status of the update manager
  """
  @spec status(GenServer.server()) :: UpdateManager.status()
  defdelegate status(server \\ UpdateManager), to: UpdateManager

  @doc """
  Restart the socket and device channel.

  After `going_to_sleep/2`, this is how a device that woke reconnects.
  """
  @spec reconnect(GenServer.server()) :: :ok
  def reconnect(server \\ Socket) do
    Socket.reconnect!(server)
  end

  @doc """
  Tell NervesHub this device is about to sleep, then close the connection.

  NervesHub shows a device that said so as asleep, with when it is due back,
  rather than as offline, and leaves the sleep out of its disconnect counts.
  Call this just before the device sleeps. It returns once the message is
  written and the connection closed, so the device can sleep straight after.
  See the [Devices That Sleep guide](device_sleep.md).

      NervesHubLink.going_to_sleep(mode: :deep, duration_ms: :timer.minutes(5))

  The connection stays closed until the device wakes. Call `reconnect/1` when
  it does. A device that said how long it would sleep also reconnects on its
  own once that much time has passed, in case nothing called `reconnect/1`. A
  device that restarts on waking connects as it always does at boot.

  ## Options

    * `:mode` - `:deep` (the default) or `:light`. NervesHub shows it to people
      and does nothing else with it. Use `:deep` when the device loses what it
      was running and starts again on waking, and `:light` when it carries on
      where it left off.
    * `:duration_ms` - how long the device will sleep, in milliseconds. Leave
      it out for a device something else wakes, such as a GPIO. This is a
      duration rather than a time, because a device that has just woken may
      not have its clock set: NervesHub counts from when the message arrives.

  NervesHub doesn't reply. A server that predates this message ignores it,
  and the connection still closes.

  Returns `{:error, :disconnected}` when the device channel isn't joined,
  leaving the connection as it was.
  """
  @spec going_to_sleep(GenServer.server(), [sleep_option()]) :: :ok | {:error, term()}
  def going_to_sleep(server \\ Socket, opts) when is_list(opts) do
    opts = Keyword.validate!(opts, mode: :deep, duration_ms: nil)
    mode = Keyword.fetch!(opts, :mode)
    duration_ms = Keyword.fetch!(opts, :duration_ms)

    if mode not in [:deep, :light] do
      raise ArgumentError, "expected :mode to be :deep or :light, got: #{inspect(mode)}"
    end

    if not (is_nil(duration_ms) or (is_integer(duration_ms) and duration_ms > 0)) do
      raise ArgumentError,
            "expected :duration_ms to be a positive integer or nil, got: #{inspect(duration_ms)}"
    end

    Socket.going_to_sleep(server, mode, duration_ms)
  end

  @doc """
  Send an update status to web
  """
  @spec send_update_status(GenServer.server(), update_status()) :: :ok
  defdelegate send_update_status(server \\ Socket, status), to: Socket

  @doc """
  Send a file to the connected console
  """
  @spec send_file(GenServer.server(), Path.t()) :: :ok | {:error, :too_large | File.posix()}
  defdelegate send_file(server \\ Socket, file_path), to: Socket

  @doc """
  How this device receives firmware, as NervesHub last reported it.

  `nil` until NervesHub says. A server too old to know about update modes never
  will, and the device goes on taking updates exactly as it did before — so treat
  `nil` as "not device managed" rather than as an error.

  ## Example

  ```elixir
  NervesHubLink.update_mode()
  #=> :automatic
  ```
  """
  @spec update_mode(GenServer.server()) :: update_mode() | nil
  defdelegate update_mode(server \\ Socket), to: Socket

  @doc """
  Whether NervesHub allows this device to manage its own updates.

  An operator grants this per device, and it is off until they do. A settings
  screen should ask before offering the choice, rather than offering a switch
  NervesHub will refuse.
  """
  @spec managed_updates_allowed?(GenServer.server()) :: boolean()
  defdelegate managed_updates_allowed?(server \\ Socket), to: Socket

  @doc """
  Ask NervesHub whether there is firmware waiting for this device.

  Allowed in every update mode, including `:off` — a frozen device can still tell
  its user that an update exists and an administrator needs to act.

  The answer carries firmware metadata and no URL. Firmware URLs are signed and
  time limited, so one is fetched when it is about to be used, by
  `start_update/1`.

  ## Example

  ```elixir
  NervesHubLink.check_for_update()
  #=> {:ok, %{available?: true, firmware_meta: %{"version" => "1.2.0"}}}
  ```
  """
  @spec check_for_update(GenServer.server()) ::
          {:ok, %{available?: boolean(), firmware_meta: map() | nil}} | {:error, term()}
  defdelegate check_for_update(server \\ Socket), to: Socket

  @doc """
  Ask NervesHub for firmware, and start applying it.

  Returns `:ok` once NervesHub has sent the update — from there it proceeds
  exactly as an update the deployment group pushed, reporting through
  `NervesHubLink.Client`.

  Deployment groups pace their rollouts, and a device asking for firmware takes a
  slot in that pacing like any other update. A device that finds none free gets
  `{:error, {:busy, minutes}}` and should try again no sooner than that.

  ## Example

  ```elixir
  NervesHubLink.start_update()
  #=> :ok

  # or, when the deployment group has no room right now
  NervesHubLink.start_update()
  #=> {:error, {:busy, 5}}
  ```
  """
  @spec start_update(GenServer.server()) :: :ok | {:error, term()}
  defdelegate start_update(server \\ Socket), to: Socket

  @doc """
  Ask NervesHub to change how this device receives firmware.

  A device can move itself between `:automatic` and `:device_managed`, and only
  once an operator has allowed it — see `managed_updates_allowed?/1`. It can never
  set `:off`, which would let a device stop its own updates and leave nobody able
  to fix it remotely.

  The mode is held by NervesHub rather than here, so it survives a reboot without
  this library persisting anything, and `update_mode/1` always reports what
  NervesHub actually has.

  Returns `{:error, :disconnected}` when there is no connection to ask over. The
  change is not queued: an application that must converge should re-assert it
  from `c:NervesHubLink.Client.connected/0`, which is safe to repeat.

  ## Example

  ```elixir
  NervesHubLink.set_update_mode(:device_managed)
  #=> :ok

  # or, when an operator has not allowed this device to manage its own updates
  NervesHubLink.set_update_mode(:device_managed)
  #=> {:error, :not_permitted}
  ```
  """
  @spec set_update_mode(GenServer.server(), :automatic | :device_managed) ::
          :ok | {:error, term()}
  defdelegate set_update_mode(server \\ Socket, mode), to: Socket

  @doc """
  Report an error your application caught to NervesHub.

  Crashes are reported on their own once the Error Reports extension is turned
  on. This is for the ones that never reach the runtime: an error you rescued,
  handled, and still want to see grouped across the fleet.

      try do
        charge(order)
      rescue
        error -> NervesHubLink.report_error(error, __STACKTRACE__, group: "payments")
      end

  ## Options

    * `:group` - group these reports under a key of your own rather than by
      their stacktrace. Every failure in a payment integration arriving through
      one HTTP client function is one issue to the person on call, and six
      issues to a stacktrace.
    * `:context` - a map of extra detail to attach to this report alone. What
      you want on *every* report belongs in
      `NervesHubLink.Extensions.ErrorReports.Config.context/0` instead.
    * `:kind` - `:error` (the default), `:exit` or `:throw`, matching the
      clauses of `try/1`.

  Returns `:ok` whether or not the extension is running, so a call to this is
  never the thing that takes an application down. The report is buffered and
  goes out with the next batch; nothing is sent at all until NervesHub attaches
  the extension.
  """
  @spec report_error(term(), Exception.stacktrace(), keyword()) :: :ok
  def report_error(error, stacktrace \\ [], opts \\ []) do
    kind = Keyword.get(opts, :kind, :error)

    kind
    |> ErrorReports.Report.from_caught(error, stacktrace, opts)
    |> ErrorReports.Collector.collect()
  rescue
    # Whatever went wrong building or buffering the report, the caller is
    # already handling an error and must not be handed a second one.
    _error -> :ok
  end
end
