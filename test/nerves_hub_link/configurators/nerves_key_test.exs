defmodule NervesHubLink.Configurator.NervesKeyTest do
  use ExUnit.Case, async: true

  alias NervesHubLink.Configurator.Config
  alias NervesHubLink.Configurator.NervesKey

  test "prefers already supplied values" do
    config = %Config{
      ssl: [
        cert: "ima cert!",
        key: "ima key!",
        cacerts: ["Everyone", "gets", "a", "CA"],
        server_name_indication: "waddup"
      ]
    }

    new_config = NervesKey.build(config)
    assert new_config.ssl == config.ssl
  end
end
