defmodule NervesHubLink.Client.DefaultTest do
  use ExUnit.Case, async: true
  alias NervesHubLink.Client.Default
  alias NervesHubLinkCommon.Message.FirmwareMetadata

  doctest Default

  test "update_available/1" do
    assert Default.update_available(-1) == :apply
  end

  describe "handle_fwup_message/1" do
    setup do
      %{meta: %FirmwareMetadata{}}
    end

    test "progress", %{meta: meta} do
      assert Default.handle_fwup_message({:progress, 25}, meta) == :ok
    end

    test "error", %{meta: meta} do
      assert Default.handle_fwup_message({:error, :any, "message"}, meta) == :ok
    end

    test "warning", %{meta: meta} do
      assert Default.handle_fwup_message({:warning, :any, "message"}, meta) == :ok
    end

    test "completion", %{meta: meta} do
      assert Default.handle_fwup_message({:ok, 0, "success"}, meta) == :ok
    end

    test "any", %{meta: meta} do
      assert Default.handle_fwup_message(:any, meta) == :ok
    end
  end

  test "handle_error/1" do
    assert Default.handle_error(:error) == :ok
  end
end
