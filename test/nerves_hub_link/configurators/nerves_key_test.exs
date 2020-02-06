defmodule NervesHubLink.Configurator.NervesKeyTest do
  use ExUnit.Case, async: false

  alias NervesHubLink.Configurator.Config

  test "prefers already supplied values" do
    config = %Config{
      ssl: [
        cert: "ima cert!",
        key: "ima key!",
        cacerts: ["Everyone", "gets", "a", "CA"],
        server_name_indication: "waddup"
      ]
    }

    new_config = NervesHubLink.Configurator.NervesKey.build(config)
    assert new_config.ssl == config.ssl
  end
end
