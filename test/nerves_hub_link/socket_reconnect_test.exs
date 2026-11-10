# SPDX-FileCopyrightText: 2026 Jon Carstens
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule NervesHubLink.SocketReconnectTest do
  @moduledoc """
  Checks that a shared-secret connection is signed afresh for every attempt.

  A signature is only good for a while, so one made once and reused is refused
  from whichever reconnect happens after it expires. These tests read the
  headers off the upgrade request itself, which is where the question is
  settled: the signing happens as the request is built, so a device that has
  been backing off for a minute signs with the time it actually connects.
  """

  # async: false because the configurator is application config.
  use ExUnit.Case, async: false

  import Mox

  alias NervesHubLink.ClientMock
  alias NervesHubLink.ClientStub
  alias NervesHubLink.Configurator.Config
  alias NervesHubLink.Socket

  @shared_secret [key: "nhd_key", secret: "secret", identifier: "device-1"]

  setup :set_mox_global

  setup do
    stub_with(ClientMock, ClientStub)
    stub(ClientMock, :connected, fn -> :ok end)
    stub(ClientMock, :reconnect_backoff, fn -> [10] end)
    stub(ClientMock, :firmware_validated?, fn -> true end)
    stub(ClientMock, :firmware_auto_revert_detected?, fn -> false end)
    stub(ClientMock, :handle_error, fn _ -> :ok end)

    previous = Application.get_env(:nerves_hub_link, :configurator)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:nerves_hub_link, :configurator, previous),
        else: Application.delete_env(:nerves_hub_link, :configurator)
    end)

    :ok
  end

  test "a shared-secret connection is signed" do
    Application.put_env(:nerves_hub_link, :configurator, NervesHubLink.Configurator.SharedSecret)

    port = listen_for_requests(1)
    start_socket(port, shared_secret: @shared_secret)

    headers = assert_upgrade_headers()

    assert headers["x-nh-key"] == "nhd_key"
    assert headers["x-nh-signature"]
    assert String.to_integer(headers["x-nh-time"]) > 0
  end

  # An app's own configurator builds the shared-secret headers itself, once, at
  # startup. What decides whether to sign again is the headers carrying a
  # signature rather than which configurator produced them.
  test "a connection an app's own configurator signed is signed again" do
    Application.put_env(:nerves_hub_link, :configurator, __MODULE__.AppConfigurator)

    port = listen_for_requests(1)

    start_socket(port,
      shared_secret: @shared_secret,
      headers: [
        {"x-custom", "keep-me"},
        {"x-nh-key", "nhd_key"},
        {"x-nh-time", "0"},
        {"x-nh-signature", "stale"}
      ]
    )

    headers = assert_upgrade_headers()

    assert headers["x-nh-signature"] != "stale"
    assert String.to_integer(headers["x-nh-time"]) > 0
    assert headers["x-custom"] == "keep-me"
  end

  # The point of the whole thing: not once, but on every attempt. Both requests
  # are asserted on rather than compared to each other, because two attempts
  # inside the same second sign identically and that is not what is at stake.
  test "it is signed again on every attempt" do
    Application.put_env(:nerves_hub_link, :configurator, __MODULE__.AppConfigurator)

    port = listen_for_requests(2)

    start_socket(port,
      shared_secret: @shared_secret,
      headers: [{"x-nh-key", "nhd_key"}, {"x-nh-time", "0"}, {"x-nh-signature", "stale"}]
    )

    first = assert_upgrade_headers()
    second = assert_upgrade_headers()

    for headers <- [first, second] do
      assert headers["x-nh-signature"] != "stale"
      assert String.to_integer(headers["x-nh-time"]) > 0
    end
  end

  test "a connection without a shared secret is left as it was" do
    Application.put_env(:nerves_hub_link, :configurator, __MODULE__.AppConfigurator)

    port = listen_for_requests(1)
    start_socket(port, headers: [{"x-custom", "keep-me"}])

    headers = assert_upgrade_headers()

    assert headers["x-custom"] == "keep-me"
    refute Map.has_key?(headers, "x-nh-signature")
    refute Map.has_key?(headers, "x-nh-key")
  end

  defp assert_upgrade_headers(timeout \\ 2_000) do
    assert_receive {:upgrade_request, headers}, timeout

    headers
  end

  # Reads the upgrade request off a plain TCP listener and closes, which the
  # device sees as an ordinary disconnect and retries - so asking for two
  # requests is how a reconnect is observed.
  defp listen_for_requests(count) do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listener)
    test_pid = self()

    spawn_link(fn ->
      Enum.each(1..count, fn _ -> forward_one_request(listener, test_pid) end)
    end)

    on_exit(fn -> :gen_tcp.close(listener) end)

    port
  end

  defp forward_one_request(listener, test_pid) do
    with {:ok, socket} <- :gen_tcp.accept(listener, 10_000),
         {:ok, request} <- :gen_tcp.recv(socket, 0, 10_000) do
      send(test_pid, {:upgrade_request, parse_headers(request)})
      :gen_tcp.close(socket)
    end
  end

  defp parse_headers(request) do
    request
    |> String.split("\r\n")
    |> Enum.drop(1)
    |> Enum.flat_map(fn line ->
      case String.split(line, ": ", parts: 2) do
        [name, value] -> [{String.downcase(name), value}]
        _ -> []
      end
    end)
    |> Map.new()
  end

  defp start_socket(port, overrides) do
    socket_opts =
      [
        url: URI.parse("ws://localhost:#{port}/socket/websocket"),
        reconnect_after_msec: [10]
      ] ++ Keyword.take(overrides, [:headers])

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
        Keyword.take(overrides, [:shared_secret])
      )

    start_supervised!(%{
      id: Socket,
      start: {Socket, :start_link, [config, [name: Socket]]}
    })
  end
end
