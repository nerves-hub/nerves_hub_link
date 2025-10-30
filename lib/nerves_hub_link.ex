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
