defmodule NervesHubLink.Configurator.DefaultTest do
  use ExUnit.Case, async: true

  alias NervesHubLink.Configurator.{Config, Default}

  test "prefers already supplied values" do
    config = %Config{
      ssl: [
        cert: "ima cert!",
        key: "ima key!",
        cacerts: ["Everyone", "gets", "a", "CA"],
        server_name_indication: "waddup"
      ]
    }

    new_config = NervesHubLink.Configurator.Default.build(config)
    assert new_config.ssl == config.ssl
  end

  test "reads values from Nerves.Runtime.KV" do
    config = Default.build(%Config{})

    ssl = config.ssl

    assert Keyword.has_key?(ssl, :cacerts)
    assert Keyword.has_key?(ssl, :cert)
    assert Keyword.has_key?(ssl, :key)
  end
end
