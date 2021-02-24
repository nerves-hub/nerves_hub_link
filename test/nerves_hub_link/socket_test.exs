defmodule NervesHubLink.SocketTest do
  use Slipstream.SocketTest, async: false

  alias NervesHubLink.{Configurator, Socket}

  test "can join the channels" do
    params = Configurator.build().params
    accept_connect(Socket)
    assert_join("device", ^params, :ok)
    assert_join("console", ^params, :ok)
  end
end
