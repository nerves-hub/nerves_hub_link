# SPDX-FileCopyrightText: 2020 Jacob Arellano
# SPDX-FileCopyrightText: 2020 Jon Carstens
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule NervesHubLink.ConfiguratorTest do
  # async: false because some tests change application config.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias NervesHubLink.Configurator
  alias NervesHubLink.Configurator.Config

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

  describe "the timeout options" do
    # Each of these is read at its point of use as no bound at all when it
    # cannot be used, so a value that is not a number has to be caught here or
    # it silently turns the bound off.
    test "a value that is not a number is refused and the default kept" do
      put_env(:heartbeat_interval_msec, "30000")

      log =
        capture_log(fn ->
          assert Configurator.build().heartbeat_interval_msec ==
                   %Config{}.heartbeat_interval_msec
        end)

      assert log =~ "heartbeat_interval_msec"
      assert log =~ ~s("30000")
    end

    test "a negative value is refused and the default kept" do
      put_env(:upgrade_timeout_msec, -1)

      log =
        capture_log(fn ->
          assert Configurator.build().upgrade_timeout_msec == %Config{}.upgrade_timeout_msec
        end)

      assert log =~ "upgrade_timeout_msec"
    end

    # Zero is how each bound is turned off, so it has to survive untouched.
    test "zero is kept" do
      put_env(:connect_timeout_msec, 0)
      put_env(:send_timeout_msec, 0)

      log =
        capture_log(fn ->
          config = Configurator.build()

          assert config.connect_timeout_msec == 0
          assert config.send_timeout_msec == 0
        end)

      refute log =~ "non-negative integer"
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
