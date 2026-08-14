# SPDX-FileCopyrightText: 2026 Josh Kalderimis
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule NervesHubLink.UpdateManager.StreamingUpdaterTest do
  @moduledoc """
  End to end tests for the default update strategy.

  These run a real download over HTTP and hand the bytes to a real `fwup`, so
  they cover the parts of an update that only show up when the pieces are
  connected: signature verification, the fwup environment, and the status
  updates NervesHub relies on to track a device through an update.
  """

  use ExUnit.Case, async: false

  import Mox

  alias Fwup.TestSupport.Fixtures
  alias NervesHubLink.ClientMock
  alias NervesHubLink.ClientStub
  alias NervesHubLink.FwupConfig
  alias NervesHubLink.Message.FirmwareMetadata
  alias NervesHubLink.Message.UpdateInfo
  alias NervesHubLink.Support.FirmwareFilePlug
  alias NervesHubLink.Support.SocketStub
  alias NervesHubLink.Support.Utils
  alias NervesHubLink.UpdateManager
  alias NervesHubLink.UpdateManager.StreamingUpdater

  # Downloading and applying a 1KB firmware is quick, but starting fwup and
  # running the port isn't instant. Be generous so this isn't flaky on CI.
  @timeout 10_000

  # The `secret_upgrade` task in the test firmware encrypts with this key, and
  # fwup fails with a bad AES key if the environment isn't passed through.
  @super_secret "1234567890123456789012345678901234567890123456789012345678901234"

  setup :set_mox_global

  setup do
    test_pid = self()

    _ = start_supervised!({SocketStub, test_pid})

    stub_with(ClientMock, ClientStub)

    stub(ClientMock, :handle_fwup_message, fn message ->
      send(test_pid, {:fwup, message})
      :ok
    end)

    stub(ClientMock, :reboot, fn ->
      send(test_pid, :reboot)
      :ok
    end)

    unique = System.unique_integer([:positive])
    key_name = "streaming-updater-#{unique}"
    :ok = Fixtures.gen_key_pair(key_name)

    {:ok, firmware_path} =
      Fixtures.create_signed_firmware(key_name, "unsigned-#{unique}", "signed-#{unique}")

    devpath = Path.join(System.tmp_dir!(), "fwup_output_#{unique}")
    _ = File.rm(devpath)
    on_exit(fn -> File.rm(devpath) end)

    {:ok,
     devpath: devpath,
     firmware_path: firmware_path,
     public_key: Fixtures.get_public_key(key_name),
     unique: unique,
     update_info: serve_firmware(firmware_path)}
  end

  describe "applying an update" do
    test "downloads, verifies and applies a signed firmware update", context do
      manager = start_manager(fwup_config(context.devpath))

      assert UpdateManager.apply_update(manager, context.update_info, [context.public_key]) ==
               :updating

      assert_receive {:update_status, :received}, @timeout
      assert_receive {:fwup, {:ok, 0, _message}}, @timeout
      assert_receive {:update_status, :completed}, @timeout

      assert File.read!(context.devpath) =~ "Hello, world!"

      assert UpdateManager.status(manager) == :idle
      assert UpdateManager.currently_downloading_uuid(manager) == nil
    end

    test "reboots the device once the update has been applied", context do
      manager = start_manager(fwup_config(context.devpath))

      assert UpdateManager.apply_update(manager, context.update_info, [context.public_key]) ==
               :updating

      assert_receive :reboot, @timeout
      assert UpdateManager.status(manager) == :idle
    end

    test "reports progress while downloading and applying", context do
      manager = start_manager(fwup_config(context.devpath))

      assert UpdateManager.apply_update(manager, context.update_info, [context.public_key]) ==
               :updating

      assert_receive {:update_status, {:started, _network_interface}}, @timeout
      assert_receive {:fwup, {:progress, _percent}}, @timeout
      assert_receive {:update_status, {:updating, percent}}, @timeout
      assert percent in 0..100
    end

    test "passes fwup_env through to fwup", context do
      # The `secret_upgrade` task can only run when SUPER_SECRET reaches fwup,
      # otherwise fwup fails with a bad AES key.
      config = %FwupConfig{
        fwup_devpath: context.devpath,
        fwup_task: "secret_upgrade",
        fwup_env: [{"SUPER_SECRET", @super_secret}]
      }

      manager = start_manager(config)

      assert UpdateManager.apply_update(manager, context.update_info, [context.public_key]) ==
               :updating

      assert_receive {:fwup, {:ok, 0, _message}}, @timeout
      assert_receive {:update_status, :completed}, @timeout
    end
  end

  describe "when the firmware can't be verified" do
    test "reports a failure for firmware signed by an unknown key", context do
      other_key = "streaming-updater-other-#{context.unique}"
      :ok = Fixtures.gen_key_pair(other_key)

      manager = start_manager(fwup_config(context.devpath))

      assert UpdateManager.apply_update(manager, context.update_info, [
               Fixtures.get_public_key(other_key)
             ]) == :updating

      assert_receive {:update_status, {:failed, message}}, @timeout
      assert message =~ "FWUP error"

      assert UpdateManager.status(manager) == :idle
    end

    test "reports a failure for a corrupt firmware file", context do
      {:ok, corrupt_path} =
        Fixtures.corrupt_firmware_file(context.firmware_path, "corrupt-#{context.unique}")

      update_info = serve_firmware(corrupt_path)

      manager = start_manager(fwup_config(context.devpath))

      assert UpdateManager.apply_update(manager, update_info, [context.public_key]) == :updating

      assert_receive {:update_status, {:failed, message}}, @timeout
      assert message =~ "FWUP error"

      assert UpdateManager.status(manager) == :idle
    end
  end

  defp start_manager(%FwupConfig{} = fwup_config) do
    start_supervised!(%{
      id: UpdateManager,
      start: {UpdateManager, :start_link, [{fwup_config, StreamingUpdater}]}
    })
  end

  defp fwup_config(devpath) do
    %FwupConfig{fwup_devpath: devpath, fwup_task: "upgrade"}
  end

  defp serve_firmware(path) do
    {:ok, _server, port} = Utils.supervise_plug(FirmwareFilePlug, path: path)

    %UpdateInfo{
      firmware_url: URI.parse("http://localhost:#{port}/#{Path.basename(path)}"),
      firmware_meta: %FirmwareMetadata{uuid: "8a8b902c-d1a9-58aa-6111-04ab57c2f2a8"}
    }
  end
end
