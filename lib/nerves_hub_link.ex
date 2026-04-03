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

  NervesHubLink manages the device's WebSocket connection to NervesHub along
  with firmware updates, archives, extensions, and remote console access.

  ## Starting as an application (default)

  When added as a dependency, the `:nerves_hub_link` OTP application starts
  automatically. It reads configuration from your application environment and
  connects using `NervesHubLink.Configurator.build/0`:

      # config/config.exs
      config :nerves_hub_link,
        host: "your-nerveshub-instance.com",
        connect: true

  Set `connect: false` to disable the automatic connection (useful in tests).

  ## Starting in your own supervision tree

  For more control, disable the automatic connection and start NervesHubLink
  directly in your supervision tree with a `NervesHubLink.Configurator.Config`
  struct:

      # config/config.exs
      config :nerves_hub_link, connect: false

      # In your application supervisor
      config = NervesHubLink.Configurator.build()
      children = [{NervesHubLink, config}]

  This is useful when you need to control startup ordering, pass a custom
  `identifier` for multi-instance scenarios, or build config dynamically.

  ## Multiple instances

  Each NervesHubLink instance is scoped by a device `identifier` (defaults
  to `Nerves.Runtime.serial_number/0`). All internal processes register with
  names derived from the identifier, allowing multiple instances to coexist
  in the same BEAM VM:

      config_a = %{NervesHubLink.Configurator.build() | identifier: "device-a"}
      config_b = %{NervesHubLink.Configurator.build() | identifier: "device-b"}

      children = [
        {NervesHubLink, config_a},
        {NervesHubLink, config_b}
      ]

  ## Utility functions

  This module also provides functions for checking connection status,
  reconnecting, sending files to a connected console, and more. These
  default to the singleton Socket process but accept an optional server
  argument for multi-instance use.
  """

  use Supervisor

  alias NervesHubLink.ArchiveManager
  alias NervesHubLink.Configurator.Config
  alias NervesHubLink.Extensions
  alias NervesHubLink.FwupConfig
  alias NervesHubLink.Socket
  alias NervesHubLink.SupportScriptsManager
  alias NervesHubLink.UpdateManager

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

  @spec __process_name__(String.t(), module()) :: atom()
  def __process_name__(identifier, module) do
    short = module |> Module.split() |> List.last()
    :"#{identifier}_#{short}"
  end

  @spec start_link(Config.t()) :: Supervisor.on_start()
  def start_link(config) do
    Supervisor.start_link(__MODULE__, config,
      name: __process_name__(config.identifier, __MODULE__)
    )
  end

  @impl Supervisor
  def init(config) do
    fwup_config = %FwupConfig{
      fwup_devpath: config.fwup_devpath,
      fwup_task: config.fwup_task,
      fwup_extra_options: config.fwup_extra_options,
      fwup_env: config.fwup_env
    }

    id = config.identifier

    children = [
      {DynamicSupervisor, name: __process_name__(id, NervesHubLink.ExtensionsSupervisor)},
      {Extensions, id},
      {UpdateManager, {id, fwup_config, config.updater}},
      {ArchiveManager, {id, config}},
      {Socket, config},
      {Task.Supervisor, name: __process_name__(id, NervesHubLink.SupportScriptsTaskSupervisor)},
      {SupportScriptsManager, id}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

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
  @spec status(GenServer.server()) :: NervesHubLink.UpdateManager.status()
  defdelegate status(server \\ Socket), to: NervesHubLink.UpdateManager

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
end
