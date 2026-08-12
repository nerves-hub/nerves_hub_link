# SPDX-FileCopyrightText: 2026 Josh Kalderimis
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule NervesHubLink.SocketConnectionTest do
  @moduledoc """
  Checks that the device actually opens a connection.

  Every other socket test runs Slipstream in test mode, which skips connection
  setup entirely, so none of them can tell whether the device can reach a server
  at all. This one points the real socket at a plain TCP listener and reads the
  HTTP upgrade request off the wire. That covers the configuration handed to
  Slipstream - the URI, the serializer, the headers - which is otherwise only
  exercised in production.
  """

  use ExUnit.Case, async: false

  import Mox

  alias NervesHubLink.Configurator.Config
  alias NervesHubLink.Socket

  setup :set_mox_global

  setup do
    stub_with(NervesHubLink.ClientMock, NervesHubLink.ClientStub)
    stub(NervesHubLink.ClientMock, :connected, fn -> :ok end)
    stub(NervesHubLink.ClientMock, :reconnect_backoff, fn -> [1_000] end)
    stub(NervesHubLink.ClientMock, :firmware_validated?, fn -> true end)
    stub(NervesHubLink.ClientMock, :firmware_auto_revert_detected?, fn -> false end)

    :ok
  end

  test "the device sends a websocket upgrade request" do
    port = listen_for_one_request()

    start_socket(port)

    assert %{method: "GET", path: path} = assert_upgrade_request()
    assert path =~ "/socket/websocket"
  end

  test "the upgrade request asks for the Phoenix v2 protocol by default" do
    port = listen_for_one_request()

    start_socket(port)

    assert %{path: path} = assert_upgrade_request()
    assert path =~ "vsn=2.0.0"
  end

  test "the upgrade request carries the websocket handshake headers" do
    port = listen_for_one_request()

    start_socket(port)

    assert %{headers: headers} = assert_upgrade_request()
    assert headers["upgrade"] == "websocket"
    assert Map.has_key?(headers, "sec-websocket-key")
  end

  test "configured headers are sent" do
    port = listen_for_one_request()

    start_socket(port, socket: [headers: [{"x-device", "test-device"}]])

    assert %{headers: headers} = assert_upgrade_request()
    assert headers["x-device"] == "test-device"
  end

  describe "with the msgpack serializer configured" do
    test "the upgrade request asks for the msgpack protocol version" do
      port = listen_for_one_request()

      start_socket(port, serializer: :msgpack)

      assert %{path: path} = assert_upgrade_request()
      assert path =~ "vsn=3.0.0"
    end
  end

  describe "with an unusable serializer configured" do
    test "the device connects with JSON rather than refusing to connect" do
      port = listen_for_one_request()

      start_socket(port, serializer: :something_else)

      assert %{path: path} = assert_upgrade_request()
      assert path =~ "vsn=2.0.0"
    end
  end

  # Accepts one connection and forwards the request it receives to the test.
  # A plain listener is enough: nothing here needs a websocket server, only
  # proof that the device got as far as asking for the upgrade.
  defp listen_for_one_request() do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listener)

    test_pid = self()

    spawn_link(fn ->
      with {:ok, socket} <- :gen_tcp.accept(listener, 10_000),
           {:ok, request} <- :gen_tcp.recv(socket, 0, 10_000) do
        send(test_pid, {:upgrade_request, request})
      end

      :gen_tcp.close(listener)
    end)

    on_exit(fn -> :gen_tcp.close(listener) end)

    port
  end

  defp assert_upgrade_request() do
    assert_receive {:upgrade_request, request}, 10_000

    [request_line | header_lines] = String.split(request, "\r\n")
    [method, path | _] = String.split(request_line, " ")

    headers =
      for line <- header_lines,
          [name, value] <- [String.split(line, ": ", parts: 2)],
          into: %{},
          do: {String.downcase(name), value}

    %{method: method, path: path, headers: headers}
  end

  defp start_socket(port, overrides \\ []) do
    socket_opts =
      Keyword.merge(
        [
          url: URI.parse("ws://localhost:#{port}/socket/websocket"),
          reconnect_after_msec: [1_000]
        ],
        Keyword.get(overrides, :socket, [])
      )

    config =
      struct(
        %Config{
          connect_wait_for_network: false,
          data_path: System.tmp_dir!(),
          heartbeat_interval_msec: 30_000,
          params: %{},
          rejoin_after: [1_000],
          remote_iex: false,
          socket: socket_opts
        },
        Keyword.delete(overrides, :socket)
      )

    start_supervised!(%{
      id: Socket,
      start: {Socket, :start_link, [config, [name: Socket]]}
    })
  end
end
