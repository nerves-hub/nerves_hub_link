# SPDX-FileCopyrightText: 2026 Ky Bishop
# SPDX-License-Identifier: Apache-2.0
#
defmodule NervesHubLink.NetworkInterfaceTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias NervesHubLink.NetworkInterface

  describe "from_uri/1" do
    test "identifies the loopback interface for a localhost URI" do
      # Routing to 127.0.0.1 always selects the loopback interface (lo on Linux, lo0 on macOS).
      log =
        capture_log(fn ->
          result = NetworkInterface.from_uri(%URI{host: "127.0.0.1", port: 80})
          assert String.starts_with?(result, "lo")
        end)

      refute log =~ "[NervesHubLink.NetworkInterface]"
    end

    test "defaults port to 443 when port is nil" do
      # wss:// URIs have no registered default port in Elixir's URI module, so the field arrives
      # as nil. The routing lookup ignores the port for the kernel route decision, so the result
      # must match the plain IPv4 case above.
      log =
        capture_log(fn ->
          result = NetworkInterface.from_uri(%URI{host: "127.0.0.1", port: nil})
          assert String.starts_with?(result, "lo")
        end)

      refute log =~ "[NervesHubLink.NetworkInterface]"
    end

    test "identifies the loopback interface for an IPv6 localhost URI" do
      # ::1 fails IPv4 resolution, triggering resolve/1's :inet6 fallback.
      # The socket must be opened with [:inet6] to connect to the IPv6 address.
      # Also exercises Enum.any? matching IPv6 tuples in inet.getifaddrs attrs.
      log =
        capture_log(fn ->
          result = NetworkInterface.from_uri(%URI{host: "::1", port: 80})
          assert String.starts_with?(result, "lo")
        end)

      refute log =~ "[NervesHubLink.NetworkInterface]"
    end

    test "returns nil and logs when the host cannot be resolved" do
      # An empty string causes :inet.getaddr to return {:error, :einval} immediately — no DNS
      # query, no network dependency.
      log =
        capture_log(fn ->
          assert NetworkInterface.from_uri(%URI{host: "", port: 443}) == nil
        end)

      assert log =~ "[NervesHubLink.NetworkInterface] Could not determine network interface for"
    end

    test "returns nil and logs when host is nil" do
      # String.to_charlist(nil) raises ArgumentError; the rescue block must catch it and return nil.
      log =
        capture_log(fn ->
          assert NetworkInterface.from_uri(%URI{host: nil, port: 443}) == nil
        end)

      assert log =~ "[NervesHubLink.NetworkInterface] Could not determine network interface"
    end
  end
end
