# SPDX-FileCopyrightText: 2026 Ky Bishop
# SPDX-License-Identifier: Apache-2.0
#
defmodule NervesHubLink.Socket.NetworkInterfaceTest do
  # Slipstream.SocketTest simulates the test process as the remote server,
  # so tests must run synchronously to avoid cross-test interference.
  use Slipstream.SocketTest

  import Mox

  alias NervesHubLink.Configurator.Config
  alias NervesHubLink.FwupConfig
  alias NervesHubLink.UpdateManager

  # Tests are async: false (Slipstream.SocketTest requirement), so global Mox mode is safe
  # and avoids the chicken-and-egg problem of allowing a pid that doesn't exist yet.
  setup :set_mox_global
  setup :verify_on_exit!

  setup do
    stub(NervesHubLink.ClientMock, :connected, fn -> :ok end)
    stub(NervesHubLink.ClientMock, :firmware_validated?, fn -> true end)
    stub(NervesHubLink.ClientMock, :firmware_auto_revert_detected?, fn -> false end)
    stub(NervesHubLink.ClientMock, :handle_error, fn _reason -> :ok end)
    # Zero-delay reconnect so disconnect/reconnect cycle completes without sleeping.
    stub(NervesHubLink.ClientMock, :reconnect_backoff, fn -> [0] end)

    config = %Config{
      socket: [
        url: URI.parse("ws://127.0.0.1:80/socket"),
        test_mode?: true,
        reconnect_after_msec: [0]
      ],
      connect_wait_for_network: false,
      remote_iex: false
    }

    start_supervised!(%{
      id: UpdateManager,
      start:
        {UpdateManager, :start_link,
         [
           {%FwupConfig{}, NervesHubLink.UpdateManager.UpdaterMock},
           [name: NervesHubLink.UpdateManager]
         ]}
    })

    client = start_supervised!({NervesHubLink.Socket, config})

    %{client: client}
  end

  test "reports network interface on first join", %{client: client} do
    connect_and_assert_join(client, "device", %{}, :ok)

    assert_push("device", "report_network_interface", %{interface: interface})
    assert is_binary(interface)
  end

  test "does not push when interface is unchanged after a second check", %{client: client} do
    connect_and_assert_join(client, "device", %{}, :ok)
    assert_push("device", "report_network_interface", %{interface: _} = params)

    # Trigger a second lookup — interface is the same, no push should fire.
    send(client, :get_network_interface)

    refute_push("device", "report_network_interface", ^params)
  end

  test "does not re-push network interface on reconnect when interface is unchanged", %{
    client: client
  } do
    connect_and_assert_join(client, "device", %{}, :ok)
    assert_push("device", "report_network_interface", %{interface: _} = params)

    # Simulate the server closing the connection (e.g. a flapping device heartbeat timeout).
    disconnect(client, :heartbeat_timeout)

    # The socket reconnects and rejoins the device topic.
    connect_and_assert_join(client, "device", %{}, :ok)

    # The interface assign persists across the reconnect cycle — no duplicate push.
    refute_push("device", "report_network_interface", ^params)
  end
end
