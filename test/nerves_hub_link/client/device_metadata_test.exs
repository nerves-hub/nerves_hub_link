# SPDX-FileCopyrightText: 2026 Josh Kalderimis
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule NervesHubLink.Client.DeviceMetadataTest.Venue do
  @moduledoc false
  @spec name() :: String.t()
  def name(), do: "the shed"

  @spec on_fire() :: no_return()
  def on_fire(), do: raise("the sensor is on fire")
end

defmodule NervesHubLink.Client.DeviceMetadataTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Mox

  alias NervesHubLink.Client
  alias NervesHubLink.Client.DeviceMetadataTest.Venue
  alias NervesHubLink.ClientDummy
  alias NervesHubLink.ClientMock

  setup do
    on_exit(fn ->
      Application.put_env(:nerves_hub_link, :client, ClientMock)
      Application.delete_env(:nerves_hub_link, :metadata)
      Application.delete_env(:nerves_hub_link, :health)
    end)

    :ok
  end

  describe "a client implementing the callback" do
    setup :verify_on_exit!

    test "is where the metadata comes from" do
      expect(ClientMock, :device_metadata, fn -> %{"placement" => "the shed"} end)

      assert Client.device_metadata() == %{"placement" => "the shed"}
    end

    test "is asked even when metadata is configured" do
      Application.put_env(:nerves_hub_link, :metadata, %{"placement" => "the config"})
      expect(ClientMock, :device_metadata, fn -> %{"placement" => "the client"} end)

      assert Client.device_metadata() == %{"placement" => "the client"}
    end

    test "has its keys normalized to strings" do
      expect(ClientMock, :device_metadata, fn -> %{placement: "the shed"} end)

      assert Client.device_metadata() == %{"placement" => "the shed"}
    end

    test "reports nothing when it answers with something that isn't a map" do
      expect(ClientMock, :device_metadata, fn -> "the shed" end)

      assert capture_log(fn -> assert Client.device_metadata() == %{} end) =~ "Invalid response"
    end

    test "reports nothing when it raises" do
      expect(ClientMock, :device_metadata, fn -> Venue.on_fire() end)

      assert capture_log(fn -> assert Client.device_metadata() == %{} end) =~ "an error occurred"
    end
  end

  describe "a client without the callback" do
    setup do
      Application.put_env(:nerves_hub_link, :client, ClientDummy)
      :ok
    end

    test "has no metadata when none is configured" do
      assert Client.device_metadata() == %{}
    end

    test "reads the `:metadata` config" do
      Application.put_env(:nerves_hub_link, :metadata, %{"placement" => "the shed"})

      assert Client.device_metadata() == %{"placement" => "the shed"}
    end

    test "calls an MFA for the value" do
      Application.put_env(:nerves_hub_link, :metadata, %{"placement" => {Venue, :name, []}})

      assert Client.device_metadata() == %{"placement" => "the shed"}
    end

    test "normalizes keys to strings" do
      Application.put_env(:nerves_hub_link, :metadata, placement: "the shed")

      assert Client.device_metadata() == %{"placement" => "the shed"}
    end

    test "falls back to where health kept metadata" do
      Application.put_env(:nerves_hub_link, :health, metadata: %{"placement" => "the shed"})

      assert Client.device_metadata() == %{"placement" => "the shed"}
    end

    test "prefers `:metadata` over the health config" do
      Application.put_env(:nerves_hub_link, :metadata, %{"placement" => "the new key"})
      Application.put_env(:nerves_hub_link, :health, metadata: %{"placement" => "the old key"})

      assert Client.device_metadata() == %{"placement" => "the new key"}
    end

    test "an MFA that raises costs the metadata and nothing else" do
      Application.put_env(:nerves_hub_link, :metadata, %{"placement" => {Venue, :on_fire, []}})

      assert capture_log(fn -> assert Client.device_metadata() == %{} end) =~
               "could not be collected"
    end
  end
end
