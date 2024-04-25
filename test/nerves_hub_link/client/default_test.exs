defmodule NervesHubLink.Client.DefaultTest do
  use ExUnit.Case, async: true
  alias NervesHubLink.Support.TestClient
  alias NervesHubLink.Message.{FirmwareMetadata, UpdateInfo}

  doctest TestClient

  @update_info %UpdateInfo{
    firmware_url: "https://nerves-hub.org/firmware/1234",
    firmware_meta: %FirmwareMetadata{}
  }

  test "update_available/1" do
    assert TestClient.update_available(@update_info) == :apply
  end

  test "update_available with same uuid" do
    update_info =
      put_in(@update_info.firmware_meta.uuid, Nerves.Runtime.KV.get_active("nerves_fw_uuid"))

    assert TestClient.update_available(update_info) == :ignore
  end

  describe "handle_fwup_message/1" do
    test "progress" do
      assert TestClient.handle_fwup_message({:progress, 25}) == :ok
    end

    test "error" do
      assert TestClient.handle_fwup_message({:error, :any, "message"}) == :ok
    end

    test "warning" do
      assert TestClient.handle_fwup_message({:warning, :any, "message"}) == :ok
    end

    test "completion" do
      assert TestClient.handle_fwup_message({:ok, 0, "success"}) == :ok
    end

    test "any" do
      assert TestClient.handle_fwup_message(:any) == :ok
    end
  end

  test "handle_error/1" do
    assert TestClient.handle_error(:error) == :ok
  end
end
