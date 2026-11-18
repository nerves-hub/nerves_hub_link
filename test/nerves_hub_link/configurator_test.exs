# SPDX-FileCopyrightText: 2020 Jacob Arellano
# SPDX-FileCopyrightText: 2020 Jon Carstens
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule NervesHubLink.ConfiguratorTest do
  # async: false because some tests change application config.
  use ExUnit.Case, async: false

  alias NervesHubLink.Configurator

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

  describe "the socket's User-Agent" do
    test "names this library and its version" do
      config = Configurator.build()

      assert user_agents(config) == [Configurator.user_agent()]
      assert "NHL/" <> version = Configurator.user_agent()
      assert {:ok, _version} = Version.parse(version)
    end

    test "is added after a shared secret replaces the headers" do
      put_env(:configurator, Configurator.SharedSecret)

      put_env(:shared_secret,
        product_key: "nhp_test",
        product_secret: "test-secret",
        identifier: "tnh-unit-test"
      )

      config = Configurator.build()

      assert user_agents(config) == [Configurator.user_agent()]
      assert List.keymember?(config.socket[:headers], "x-nh-signature", 0)
    end

    test "is left as the app configured it" do
      put_env(:socket, headers: [{"User-Agent", "custom#acme-link/1.4.0"}])

      config = Configurator.build()

      assert user_agents(config) == ["custom#acme-link/1.4.0"]
    end
  end

  defp user_agents(config) do
    for {name, value} <- config.socket[:headers], String.downcase(name) == "user-agent", do: value
  end

  defp put_env(key, value) do
    previous = Application.fetch_env(:nerves_hub_link, key)
    Application.put_env(:nerves_hub_link, key, value)

    on_exit(fn ->
      case previous do
        {:ok, previous} -> Application.put_env(:nerves_hub_link, key, previous)
        :error -> Application.delete_env(:nerves_hub_link, key)
      end
    end)
  end
end
