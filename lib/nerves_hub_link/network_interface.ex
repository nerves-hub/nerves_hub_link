# SPDX-FileCopyrightText: 2026 Josh Kalderimis
# SPDX-FileCopyrightText: 2026 Nate Shoemaker
# SPDX-FileCopyrightText: 2026 Ky Bishop

# SPDX-License-Identifier: Apache-2.0
#
defmodule NervesHubLink.NetworkInterface do
  @moduledoc """
  Functions for determining the network interface when connecting to NervesHub and downloading firmware.
  """

  require Logger

  @doc """
  Determine the network interface used to reach the given URI.

  Opens a UDP socket and connects it to the target host/port. This is a purely
  local kernel routing-table lookup — no packets are sent to the server. The local
  address assigned to the socket reveals which interface the OS would use, which is
  then matched against the system interface list.
  """
  @spec from_uri(URI.t()) :: nil | binary()
  def from_uri(%URI{host: host, port: port}) do
    with {:ok, ip} <- resolve(host),
         {:ok, udp} <- :gen_udp.open(0, [socket_family(ip)]) do
      result =
        with :ok <- :gen_udp.connect(udp, ip, port || 443),
             {:ok, {local_ip, _}} <- :inet.sockname(udp) do
          interface_from_address(local_ip)
        else
          error ->
            Logger.warning(
              "[NervesHubLink.NetworkInterface] Could not determine network interface for #{host}: #{inspect(error)}"
            )

            nil
        end

      :gen_udp.close(udp)

      result
    else
      error ->
        Logger.warning(
          "[NervesHubLink.NetworkInterface] Could not determine network interface for #{host}: #{inspect(error)}"
        )

        nil
    end
  rescue
    err ->
      Logger.warning(
        "[NervesHubLink.NetworkInterface] Could not determine network interface: #{inspect(err)}"
      )

      nil
  end

  defp socket_family({_, _, _, _}), do: :inet
  defp socket_family({_, _, _, _, _, _, _, _}), do: :inet6

  defp resolve(host) do
    charlist = String.to_charlist(host)

    case :inet.getaddr(charlist, :inet) do
      {:ok, _} = ok -> ok
      {:error, _} -> :inet.getaddr(charlist, :inet6)
    end
  end

  defp interface_from_address(address) do
    with {:ok, interfaces} <- get_interfaces(),
         {:ok, interface_name} <- find_interface_by_address(interfaces, address) do
      List.to_string(interface_name)
    end
  end

  defp get_interfaces() do
    with {:error, reason} <- :inet.getifaddrs() do
      Logger.warning(
        "[NervesHubLink.NetworkInterface] Could not list network interfaces: #{inspect(reason)}"
      )

      nil
    end
  end

  defp find_interface_by_address(interfaces, address) do
    case Enum.find(interfaces, fn {_name, attrs} ->
           Enum.any?(attrs, &(&1 == {:addr, address}))
         end) do
      nil ->
        Logger.warning(
          "[NervesHubLink.NetworkInterface] No network interface found with local address #{inspect(address)}"
        )

        nil

      {interface_name, _attrs} ->
        {:ok, interface_name}
    end
  end
end
