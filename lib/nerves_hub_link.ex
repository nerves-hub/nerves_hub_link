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

  alias NervesHubLink.Configurator
  alias NervesHubLink.Socket

  @type update_status ::
          :received
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
  @spec connected?() :: boolean()
  def connected?() do
    Socket.check_connection(:device)
  end

  @doc """
  Checks if the device is connected to the NervesHub console channel.
  """
  @spec console_connected?() :: boolean()
  def console_connected?() do
    Socket.check_connection(:console)
  end

  @doc """
  Checks if the device is connected to the NervesHub extensions channel.
  """
  @spec extensions_connected?() :: boolean()
  def extensions_connected?() do
    Socket.check_connection(:extensions)
  end

  @doc """
  Checks if the device has a socket connection with NervesHub
  """
  @spec socket_connected?() :: boolean()
  def socket_connected?() do
    Socket.check_connection(:socket)
  end

  @doc """
  Return whether there's currently an active console session
  """
  @spec console_active?() :: boolean()
  defdelegate console_active?, to: Socket

  @doc """
  Current status of the update manager
  """
  @spec status :: NervesHubLink.UpdateManager.status()
  defdelegate status(), to: NervesHubLink.UpdateManager

  @doc """
  Refresh the config used by the socket connection
  """
  @spec refresh_config() :: :ok
  def refresh_config() do
    Configurator.build()
    |> Socket.refresh_config()
  end

  @doc """
  Establish a connection to the configured NervesHub platform
  """
  @spec establish_connection() :: :ok
  defdelegate establish_connection(), to: Socket

  @doc """
  Restart the socket and device channel
  """
  @spec reconnect() :: :ok
  defdelegate reconnect(), to: Socket

  @doc """
  Disconnect the socket, and don't reconnect
  """
  @spec disconnect!() :: :ok
  defdelegate disconnect!(), to: Socket

  @doc """
  Send an update status to web
  """
  @spec send_update_status(update_status()) :: :ok
  defdelegate send_update_status(status), to: Socket

  @doc """
  Send a file to the connected console
  """
  @spec send_file(Path.t()) :: :ok | {:error, :too_large | File.posix()}
  defdelegate send_file(file_path), to: Socket
end
