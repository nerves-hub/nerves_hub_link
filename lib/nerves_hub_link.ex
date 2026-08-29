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
  Restart the socket and device channel
  """
  @spec reconnect(GenServer.server()) :: :ok
  def reconnect(server \\ Socket) do
    Socket.reconnect!(server)
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
end
