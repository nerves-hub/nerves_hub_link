defmodule NervesHubLink.Configurator.NervesKeyTest do
  use ExUnit.Case, async: false

  alias NervesHubLink.Configurator.Config

  test "prefers already supplied values" do
    config = %Config{
      socket: [
        transport_opts: [
          socket_opts: [
            cert: "ima cert!",
            key: "ima key!",
            cacerts: ["Everyone", "gets", "a", "CA"],
            server_name_indication: "waddup"
          ]
        ]
      ]
    }

    new_config = NervesHubLink.Configurator.NervesKey.build(config)
    assert new_config.socket == config.socket
  end
end
