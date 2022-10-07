defmodule NervesHubLink.ConfiguratorTest do
  use ExUnit.Case, async: true

  test "inserts socket_opts from ssl" do
    ssl = [
      versions: [:"tlsv1.2"],
      cert: "ima cert!",
      key: "ima key!",
      cacerts: ["Everyone", "gets", "a", "CA"],
      server_name_indication: "waddup",
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
      "thisisavalidkey==",
      :not_valid,
      false,
      {:also, :not, :valid},
      nil,
      1234
    ]

    Application.put_env(:nerves_hub_link, :fwup_public_keys, keys)

    config = NervesHubLink.Configurator.build()

    assert ["thisisavalidkey=="] == config.fwup_public_keys
  end
end
