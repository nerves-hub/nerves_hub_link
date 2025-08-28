# SPDX-FileCopyrightText: 2020 Jon Carstens
# SPDX-FileCopyrightText: 2024 Josh Kalderimis
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule NervesHubLink.Configurator.DefaultTest do
  use ExUnit.Case, async: true

  alias NervesHubLink.Configurator.{Config, LocalCertKey}

  test "prefers already supplied values" do
    config = %Config{
      ssl: [
        cert: "ima cert!",
        key: "ima key!",
        cacerts: ["Everyone", "gets", "a", "CA"],
        server_name_indication: "what_is_up"
      ]
    }

    new_config = LocalCertKey.build(config)
    assert new_config.ssl == config.ssl
  end

  test "doesn't add cacerts when cacertfile is provided" do
    config = %Config{
      ssl: [
        cacertfile: ~c"/cacert.pem"
      ]
    }

    new_config = LocalCertKey.build(config)
    refute new_config.ssl[:cacerts]
  end

  test "reads values from Nerves.Runtime.KV" do
    config = LocalCertKey.build(%Config{})

    ssl = config.ssl

    assert Keyword.has_key?(ssl, :cacerts)
    assert Keyword.has_key?(ssl, :cert)
    assert Keyword.has_key?(ssl, :key)
  end
end
