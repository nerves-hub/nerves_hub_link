defmodule NervesHubLink.ClientTest do
  use ExUnit.Case, async: true
  alias NervesHubLink.{Client, ClientMock}

  @compile {:no_warn_undefined, {Not, :real, 0}}
  @compile {:no_warn_undefined, {:something, :exception, 1}}

  doctest Client

  setup do
    %NervesHubLinkCommon.Message.FirmwareMetadata{}
    |> Mox.verify_on_exit!()
  end

  test "update_available/2" do
    Mox.expect(ClientMock, :update_available, fn :data -> :apply end)
    assert Client.update_available(:data) == :apply

    Mox.expect(ClientMock, :update_available, fn :data -> :wrong end)
    assert Client.update_available(:data) == :apply

    Mox.expect(ClientMock, :update_available, fn :data -> :ignore end)
    assert Client.update_available(:data) == :ignore

    Mox.expect(ClientMock, :update_available, fn :data -> {:reschedule, 1337} end)
    assert Client.update_available(:data) == {:reschedule, 1337}
  end

  test "handle_fwup_message/2", meta do
    Mox.expect(ClientMock, :handle_fwup_message, fn :data, ^meta -> :ok end)
    assert Client.handle_fwup_message(:data, meta) == :ok
  end

  test "handle_error/2" do
    Mox.expect(ClientMock, :handle_error, fn :data -> :ok end)
    assert Client.handle_error(:data) == :ok
  end

  describe "apply_wrap doesn't propagate failures" do
    test "error", meta do
      Mox.expect(ClientMock, :handle_fwup_message, fn :data, ^meta -> raise :something end)
      assert Client.handle_fwup_message(:data, meta) == :ok
    end

    test "exit", meta do
      Mox.expect(ClientMock, :handle_fwup_message, fn :data, ^meta -> exit(:reason) end)
      assert Client.handle_fwup_message(:data, meta) == :ok
    end

    test "throw", meta do
      Mox.expect(ClientMock, :handle_fwup_message, fn :data, ^meta -> throw(:reason) end)
      assert Client.handle_fwup_message(:data, meta) == :ok
    end

    test "exception", meta do
      Mox.expect(ClientMock, :handle_fwup_message, fn :data, ^meta -> Not.real() end)
      assert Client.handle_fwup_message(:data, meta) == :ok
    end
  end
end
