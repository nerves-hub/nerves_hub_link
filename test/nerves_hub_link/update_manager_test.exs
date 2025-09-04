# SPDX-FileCopyrightText: 2023 Eric Oestrich
# SPDX-FileCopyrightText: 2024 Frank Hunleth
# SPDX-FileCopyrightText: 2024 Josh Kalderimis
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule NervesHubLink.UpdateManagerTest do
  use ExUnit.Case, async: true

  alias NervesHubLink.ClientMock
  alias NervesHubLink.{FwupConfig, UpdateManager}
  alias NervesHubLink.Message.{FirmwareMetadata, UpdateInfo}
  alias NervesHubLink.Support.{FWUPStreamPlug, Utils}
  alias NervesHubLink.UpdateManager.UpdaterMock

  describe "fwup stream" do
    setup do
      devpath = "/tmp/fwup_output"

      {:ok, plug, port} =
        Utils.supervise_with_port(fn port ->
          {Plug.Cowboy, scheme: :http, plug: FWUPStreamPlug, options: [port: port]}
        end)

      File.rm(devpath)

      update_payload = %UpdateInfo{
        firmware_url: URI.parse("http://localhost:#{port}/test.fw"),
        firmware_meta: %FirmwareMetadata{}
      }

      Mox.stub_with(NervesHubLink.ClientMock, NervesHubLink.ClientStub)

      {:ok,
       [
         plug: plug,
         update_payload: update_payload,
         devpath: "/tmp/fwup_output",
         updater: NervesHubLink.UpdateManager.UpdaterMock
       ]}
    end

    test "apply", %{update_payload: update_payload, devpath: devpath, updater: updater} do
      fwup_config = %FwupConfig{fwup_devpath: devpath}

      Mox.expect(ClientMock, :update_available, fn _ -> :apply end)
      Mox.expect(UpdaterMock, :start_update, fn _, _, _ -> {:ok, :ok} end)

      {:ok, manager} = UpdateManager.start_link({fwup_config, updater})

      Mox.allow(ClientMock, self(), manager)
      Mox.allow(UpdaterMock, self(), manager)

      assert UpdateManager.apply_update(manager, update_payload, []) == :updating
    end

    test "reschedule", %{update_payload: update_payload, devpath: devpath, updater: updater} do
      Mox.expect(ClientMock, :update_available, fn _ -> {:reschedule, 1} end)
      Mox.expect(ClientMock, :update_available, fn _ -> :apply end)
      Mox.expect(UpdaterMock, :start_update, fn _, _, _ -> {:ok, :ok} end)

      fwup_config = %FwupConfig{
        fwup_devpath: devpath
      }

      {:ok, manager} = UpdateManager.start_link({fwup_config, updater})

      Mox.allow(ClientMock, self(), manager)
      Mox.allow(UpdaterMock, self(), manager)

      assert UpdateManager.apply_update(manager, update_payload, []) == :update_rescheduled

      # wait enough milliseconds for the update to be rescheduled
      Process.sleep(5)

      assert :sys.get_state(manager).status == :updating
    end
  end
end
