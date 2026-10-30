# SPDX-FileCopyrightText: 2026 Jon Carstens
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule NervesHubLink.SocketReconnectTest do
  # async: false because the configurator is application config.
  use ExUnit.Case, async: false

  import Mox

  alias NervesHubLink.ClientMock
  alias NervesHubLink.ClientStub
  alias NervesHubLink.Configurator.Config
  alias NervesHubLink.Socket

  setup do
    stub_with(ClientMock, ClientStub)
    stub(ClientMock, :reconnect_backoff, fn -> [1_000] end)

    # An app's own configurator, as when it builds the shared-secret config itself.
    previous = Application.get_env(:nerves_hub_link, :configurator)
    Application.put_env(:nerves_hub_link, :configurator, __MODULE__.AppConfigurator)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:nerves_hub_link, :configurator, previous),
        else: Application.delete_env(:nerves_hub_link, :configurator)
    end)
  end

  defp disconnected_socket(headers) do
    config = %Config{shared_secret: [key: "nhd_key", secret: "secret", identifier: "device-1"]}

    %Slipstream.Socket{
      channel_config: %Slipstream.Configuration{
        uri: URI.parse("wss://nh.test/device-socket/websocket"),
        headers: headers
      },
      assigns: %{config: config}
    }
  end

  test "signs a shared-secret connection again, whichever configurator built it" do
    stale = [{"x-nh-key", "nhd_key"}, {"x-nh-time", "0"}, {"x-nh-signature", "stale"}]

    {:ok, socket} = Socket.handle_disconnect({:error, :closed}, disconnected_socket(stale))

    headers = Map.new(socket.channel_config.headers)
    assert headers["x-nh-key"] == "nhd_key"
    assert headers["x-nh-signature"] != "stale"
    assert String.to_integer(headers["x-nh-time"]) > 0
  end

  test "leaves a connection without a shared secret as it was" do
    {:ok, socket} = Socket.handle_disconnect({:error, :closed}, disconnected_socket([]))

    assert socket.channel_config.headers == []
  end
end
