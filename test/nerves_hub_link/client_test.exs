# SPDX-FileCopyrightText: 2019 Daniel Spofford
# SPDX-FileCopyrightText: 2019 Frank Hunleth
# SPDX-FileCopyrightText: 2020 Jon Carstens
# SPDX-FileCopyrightText: 2020 Justin Schneck
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule NervesHubLink.ClientTest do
  use ExUnit.Case, async: true

  import Mox

  alias NervesHubLink.Client
  alias NervesHubLink.ClientMock

  @compile {:no_warn_undefined, {Not, :real, 0}}
  @compile {:no_warn_undefined, {:something, :exception, 1}}

  doctest Client

  setup :verify_on_exit!

  test "firmware_validated?/0" do
    assert Client.firmware_validated?() == true
    Mox.expect(ClientMock, :firmware_validated?, fn -> false end)
    assert Client.firmware_validated?() == false
  end

  test "firmware_auto_revert_detected?/0" do
    assert Client.firmware_auto_revert_detected?() == false
    Mox.expect(ClientMock, :firmware_auto_revert_detected?, fn -> true end)
    assert Client.firmware_auto_revert_detected?() == true
  end

  test "connected/0" do
    Mox.expect(ClientMock, :connected, fn -> :ok end)
    assert Client.connected() == :ok
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

  test "handle_fwup_message/2" do
    Mox.expect(ClientMock, :handle_fwup_message, fn :data -> :ok end)
    assert Client.handle_fwup_message(:data) == :ok
  end

  test "handle_error/2" do
    Mox.expect(ClientMock, :handle_error, fn :data -> :ok end)
    assert Client.handle_error(:data) == :ok
  end

  describe "apply_wrap doesn't propagate failures" do
    test "error" do
      Mox.expect(ClientMock, :handle_fwup_message, fn :data -> raise :something end)
      assert Client.handle_fwup_message(:data) == :ok
    end

    test "exit" do
      Mox.expect(ClientMock, :handle_fwup_message, fn :data -> exit(:reason) end)
      assert Client.handle_fwup_message(:data) == :ok
    end

    test "throw" do
      Mox.expect(ClientMock, :handle_fwup_message, fn :data -> throw(:reason) end)
      assert Client.handle_fwup_message(:data) == :ok
    end

    test "exception" do
      Mox.expect(ClientMock, :handle_fwup_message, fn :data -> Not.real() end)
      assert Client.handle_fwup_message(:data) == :ok
    end
  end
end
