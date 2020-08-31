defmodule NervesHubLink.ConfiguratorTest do
  use ExUnit.Case, async: true

  test "inserts socket_opts from ssl" do
    ssl = [
      cert: "ima cert!",
      key: "ima key!",
      cacerts: ["Everyone", "gets", "a", "CA"],
      server_name_indication: "waddup",
      verify: :verify_peer
    ]

    Application.put_env(:nerves_hub_link, :ssl, ssl)

    config = NervesHubLink.Configurator.build()
    assert config.socket[:transport_opts][:socket_opts] == ssl
  end

  test "fwup_version is included in params" do
    config = NervesHubLink.Configurator.build()
    assert Map.has_key?(config.params, "nerves_fw_fwup_version")
  end
end
