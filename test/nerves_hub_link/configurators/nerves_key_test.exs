# SPDX-FileCopyrightText: 2020 Jon Carstens
# SPDX-FileCopyrightText: 2024 Josh Kalderimis
# SPDX-FileCopyrightText: 2024 Lars Wikman
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule NervesHubLink.Configurator.NervesKeyTest do
  use ExUnit.Case, async: false

  alias NervesHubLink.Configurator.Config
  alias NervesHubLink.Configurator.NervesKey

  test "prefers already supplied values" do
    config = %Config{
      ssl: [
        cert: "ima cert!",
        key: "ima key!",
        cacerts: ["Everyone", "gets", "a", "CA"],
        server_name_indication: "what_is_up"
      ]
    }

    new_config = NervesKey.build(config)
    assert new_config.ssl == config.ssl
  end
end
