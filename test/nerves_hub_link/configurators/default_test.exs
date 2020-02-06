defmodule NervesHubLink.Configurator.DefaultTest do
  use ExUnit.Case, async: false

  alias NervesHubLink.Configurator.{Config, Default}

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

    new_config = NervesHubLink.Configurator.Default.build(config)
    assert new_config.socket == config.socket
  end

  test "reads values from Nerves.Runtime.KV" do
    config = Default.build(%Config{})

    socket_opts = config.socket[:transport_opts][:socket_opts]

    assert socket_opts[:server_name_indication] == 'device.nerves-hub.org'
    assert Keyword.has_key?(socket_opts, :cacerts)
    assert Keyword.has_key?(socket_opts, :cert)
    assert Keyword.has_key?(socket_opts, :key)
  end
end
