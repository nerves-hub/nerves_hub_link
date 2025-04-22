# SPDX-FileCopyrightText: 2020 Jacob Arellano
# SPDX-FileCopyrightText: 2020 Jon Carstens
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule NervesHubLink.ConfiguratorTest do
  use ExUnit.Case, async: true

  test "inserts socket_opts from ssl" do
    ssl = [
      versions: [:"tlsv1.2"],
      cert: "ima cert!",
      key: "ima key!",
      cacerts: ["Everyone", "gets", "a", "CA"],
      server_name_indication: "what_is_up",
      verify: :verify_peer
    ]

    config = NervesHubLink.Configurator.build()
    assert config.socket[:transport_opts][:socket_opts] == ssl
  end

  test "fwup_version is included in params" do
    config = NervesHubLink.Configurator.build()
    assert Map.has_key?(config.params, "fwup_version")
  end

  test "only includes binary in fwup_public_keys" do
    keys = [
      # cspell:disable-next-line
      "thisisavalidkey==",
      :not_valid,
      false,
      {:also, :not, :valid},
      nil,
      1234
    ]

    Application.put_env(:nerves_hub_link, :fwup_public_keys, keys)

    config = NervesHubLink.Configurator.build()

    # cspell:disable-next-line
    assert ["thisisavalidkey=="] == config.fwup_public_keys
  end
end
