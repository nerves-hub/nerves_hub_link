# SPDX-FileCopyrightText: 2026 Josh Kalderimis
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule NervesHubLink.SocketConnectionTest do
  @moduledoc """
  Checks that the device actually opens a connection.

  Other socket tests answer the upgrade and get on with the protocol. This one
  stops at the upgrade request itself, reading it off a plain TCP listener, so
  that what goes into it - the URI, the protocol version, the headers - is
  checked rather than assumed.
  """

  use ExUnit.Case, async: false
  use NervesHubLink.Support.SocketHarness

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

  # The listener above accepts the connection and never answers, which is the
  # failure this bounds: nothing below the socket notices, and the heartbeat
  # that would is not running until the upgrade completes.
  test "a server that accepts the connection and never answers is given up on" do
    test_pid = self()

    stub(NervesHubLink.ClientMock, :handle_error, fn reason ->
      send(test_pid, {:handle_error, reason})
      :ok
    end)

    port = listen_without_answering()

    start_socket(port, upgrade_timeout_msec: 200)

    assert_receive {:handle_error, :upgrade_timeout}, 2_000
  end

  # A redirect that points back at the same server, so the device is sent round
  # the loop the hop limit is there to stop. Past that limit it must keep
  # trying rather than go quiet: nothing on a device would ever bring it back.
  test "a redirect loop does not leave the device off the air" do
    port = start_server(mode: :redirect, location: "/socket/websocket")

    start_socket(port, socket: [reconnect_after_msec: [10]])

    # Two hops are followed, and the attempts after the limit prove it is
    # still trying rather than sitting idle.
    for _ <- 1..5, do: assert_receive({:connection_test, :redirected}, 2_000)
  end

  # Holds the connection open without answering. `listen_for_one_request/0`
  # cannot: it closes as soon as it has the request, which the device sees as
  # an ordinary disconnect long before any upgrade timeout.
  defp listen_without_answering() do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listener)

    spawn_link(fn ->
      with {:ok, socket} <- :gen_tcp.accept(listener, 10_000),
           {:ok, _request} <- :gen_tcp.recv(socket, 0, 10_000) do
        Process.sleep(:infinity)
      end
    end)

    on_exit(fn -> :gen_tcp.close(listener) end)

    port
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
