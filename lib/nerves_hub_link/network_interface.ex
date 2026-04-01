# SPDX-FileCopyrightText: 2026 Nate Shoemaker
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule NervesHubLink.NetworkInterface do
  @moduledoc """
  Functions for determining the network interface when connecting to NervesHub and downloading firmware.
  """

  require Logger

  @doc """
  Get the network interface from a Slipstream.Socket or Mint.HTTP struct. This is used to report the
  network interface being used for the connection to NervesHub and for firmware downloads.
  """
  @spec from_socket(:ssl.socket() | :inet.socket() | Mint.Types.socket()) :: nil | binary()
  def from_socket(socket) do
    address_from_socket(socket)
    |> interface_from_address()
  rescue
    err ->
      Logger.warning(
        "[NervesHubLink] Error: could not retrieve network interface: #{inspect(err)}"
      )

      nil
  end

  defp address_from_socket({:sslsocket, _, _} = socket) do
    {:ok, {address, _}} = :ssl.sockname(socket)
    address
  end

  defp address_from_socket(socket) do
    {:ok, {address, _}} = :inet.sockname(socket)
    address
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
