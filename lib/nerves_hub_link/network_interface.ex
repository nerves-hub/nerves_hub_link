# SPDX-FileCopyrightText: 2026 Nate Shoemaker
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule NervesHubLink.NetworkInterface do
  @moduledoc """
  Functions for determining the network interface when connecting to NervesHub and downloading firmware.
  """

  require Logger

  @spec from_slipstream(Slipstream.Socket.t()) :: nil | binary()
  def from_slipstream(%Slipstream.Socket{} = socket) do
    channel_state = :sys.get_state(socket.channel_pid)

    address =
      case channel_state.conn.socket do
        {:sslsocket, _, _} ->
          {:ok, {address, _}} = :ssl.sockname(channel_state.conn.socket)
          address

        _ ->
          {:ok, {address, _}} = :socket.sockname(channel_state.conn.socket)
          address
      end

    interface_from_address(address)
  rescue
    err ->
      Logger.warning(
        "[NervesHubLink] Error: could not determine network interface for Socket: #{inspect(err)}"
      )

      nil
  end

  @spec from_mint(Mint.HTTP.t()) :: nil | binary()
  def from_mint(conn) do
    {:ok, {address, _}} = :inet.sockname(conn.socket)
    interface_from_address(address)
  rescue
    err ->
      Logger.warning(
        "[NervesHubLink] Error: could not determine network interface for Downloader: #{inspect(err)}"
      )

      nil
  end

  defp interface_from_address(address) do
    {:ok, interfaces} = :inet.getifaddrs()

    case Enum.find(interfaces, fn {_name, attrs} -> attrs[:addr] == address end) do
      {interface, _attrs} ->
        # charlist -> string
        List.to_string(interface)

      nil ->
        nil
    end
  end
end
