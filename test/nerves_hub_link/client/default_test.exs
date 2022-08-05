defmodule NervesHubLink.Client.DefaultTest do
  use ExUnit.Case, async: true
  alias NervesHubLink.Client.Default
  alias NervesHubLinkCommon.Message.{FirmwareMetadata, UpdateInfo}

  import ExUnit.CaptureIO

  doctest Default

  @update_info %UpdateInfo{
    firmware_url: "https://nerves-hub.org/firmware/1234",
    firmware_meta: %FirmwareMetadata{}
  }

  test "update_available/1" do
    assert Default.update_available(@update_info) == :apply
  end

  test "update_avialable with same uuid" do
    update_info =
      put_in(@update_info.firmware_meta.uuid, Nerves.Runtime.KV.get_active("nerves_fw_uuid"))

    assert Default.update_available(update_info) == :ignore
  end

  describe "handle_fwup_message/1" do
    test "progress" do
      assert Default.handle_fwup_message({:progress, 25}) == :ok
    end

    test "error" do
      assert Default.handle_fwup_message({:error, :any, "message"}) == :ok
    end

    test "warning" do
      assert Default.handle_fwup_message({:warning, :any, "message"}) == :ok
    end

    test "completion" do
      assert Default.handle_fwup_message({:ok, 0, "success"}) == :ok
    end

    test "any" do
      assert Default.handle_fwup_message(:any) == :ok
    end
  end

  test "handle_error/1" do
    assert Default.handle_error(:error) == :ok
  end
end
