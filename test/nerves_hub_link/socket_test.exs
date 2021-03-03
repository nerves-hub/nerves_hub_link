defmodule NervesHubLink.SocketTest do
  use Slipstream.SocketTest, async: false

  alias NervesHubLink.{Configurator, Socket}

  test "can join the channels" do
    params = Configurator.build().params
    accept_connect(Socket)
    device_params = Map.put(params, "currently_downloading_uuid", nil)
    assert_join("device", ^device_params, :ok)
    assert_join("console", ^params, :ok)
  end
end
