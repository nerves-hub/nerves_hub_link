# SPDX-FileCopyrightText: 2023 Eric Oestrich
# SPDX-FileCopyrightText: 2024 Frank Hunleth
# SPDX-FileCopyrightText: 2024 Josh Kalderimis
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule NervesHubLink.UpdateManagerTest.AlternateUpdater do
  @moduledoc """
  A minimal `NervesHubLink.UpdateManager.Updater` used to check that
  `UpdateManager.change_updater/2` takes effect.
  """

  @behaviour NervesHubLink.UpdateManager.Updater

  @impl NervesHubLink.UpdateManager.Updater
  def start_update(_update_info, _fwup_config, _fwup_public_keys) do
    {:ok, spawn(fn -> Process.sleep(:infinity) end)}
  end

  @impl NervesHubLink.UpdateManager.Updater
  def start(state), do: {:ok, state}

  @impl NervesHubLink.UpdateManager.Updater
  def handle_downloader_message(_message, state), do: {:ok, state}

  @impl NervesHubLink.UpdateManager.Updater
  def handle_fwup_message(_message, state), do: {:ok, state}

  @impl NervesHubLink.UpdateManager.Updater
  def cleanup(_state), do: :ok

  @impl NervesHubLink.UpdateManager.Updater
  def log_prefix(), do: "AlternateUpdater"
end

defmodule NervesHubLink.UpdateManagerTest do
  use ExUnit.Case, async: false

  import Mox

  alias NervesHubLink.Alarms
  alias NervesHubLink.ClientMock
  alias NervesHubLink.{FwupConfig, UpdateManager}
  alias NervesHubLink.Message.{FirmwareMetadata, UpdateInfo}
  alias NervesHubLink.Support.{FWUPStreamPlug, SocketStub, Utils}
  alias NervesHubLink.UpdateManager.UpdaterMock

  @update_alarm NervesHubLink.UpdateInProgress

  setup :set_mox_global
  setup :verify_on_exit!
  setup :reset_update_alarm

  describe "fwup stream" do
    setup do
      devpath = "/tmp/fwup_output"

      {:ok, plug, port} = Utils.supervise_plug(FWUPStreamPlug)

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

      assert UpdateManager.apply_update(manager, update_payload, []) == :updating

      assert GenServer.stop(manager) == :ok
    end

    test "reschedule", %{update_payload: update_payload, devpath: devpath, updater: updater} do
      Mox.expect(ClientMock, :update_available, fn _ -> {:reschedule, 5, "Busy"} end)

      fwup_config = %FwupConfig{
        fwup_devpath: devpath
      }

      {:ok, manager} = UpdateManager.start_link({fwup_config, updater})

      assert UpdateManager.apply_update(manager, update_payload, []) == :idle

      assert GenServer.stop(manager) == :ok
    end
  end

  describe "responding to the client's update_available/1 answer" do
    setup [:stub_client, :watch_socket]

    test "an ignored update leaves the manager idle", context do
      stub(ClientMock, :update_available, fn _ -> :ignore end)

      manager = start_manager()

      assert UpdateManager.apply_update(manager, context.update_info, []) == :idle
      assert_receive {:update_status, {:ignored, ""}}
      refute alarm_set?(@update_alarm)
    end

    test "an ignored update reports the client's reason", context do
      stub(ClientMock, :update_available, fn _ -> {:ignore, "on battery"} end)

      manager = start_manager()

      assert UpdateManager.apply_update(manager, context.update_info, []) == :idle
      assert_receive {:update_status, {:ignored, "on battery"}}
    end

    test "a rescheduled update is reported in minutes", context do
      stub(ClientMock, :update_available, fn _ -> {:reschedule, 600_000} end)

      manager = start_manager()

      assert UpdateManager.apply_update(manager, context.update_info, []) == :idle
      assert_receive {:update_status, {:reschedule, 10}}
    end

    test "a reschedule shorter than five minutes is raised to five", context do
      stub(ClientMock, :update_available, fn _ -> {:reschedule, 60_000} end)

      manager = start_manager()

      assert UpdateManager.apply_update(manager, context.update_info, []) == :idle
      assert_receive {:update_status, {:reschedule, 5}}
    end
  end

  describe "while an update is in progress" do
    setup [:stub_client, :watch_socket, :start_update]

    test "the update alarm is set" do
      assert alarm_eventually_set?(@update_alarm)
    end

    test "the manager reports the firmware uuid being downloaded", context do
      assert UpdateManager.currently_downloading_uuid(context.manager) ==
               context.update_info.firmware_meta.uuid
    end

    test "the update is reported as received", _context do
      assert_received {:update_status, :received}
    end

    test "a duplicate update message doesn't restart the update", context do
      # start_update/1 is stubbed to be called exactly once, so a second call
      # would be an unexpected call and fail verification on exit
      assert UpdateManager.apply_update(context.manager, context.update_info, []) == :updating

      assert UpdateManager.currently_downloading_uuid(context.manager) ==
               context.update_info.firmware_meta.uuid
    end
  end

  describe "when the updater exits" do
    setup [:stub_client, :watch_socket, :start_update]

    test "a completed update is reported and the device reboots", context do
      exit_updater(context, {:shutdown, :update_complete})

      assert_receive {:update_status, :completed}
      assert_receive :reboot

      assert UpdateManager.status(context.manager) == :idle
      assert UpdateManager.currently_downloading_uuid(context.manager) == nil
      assert alarm_eventually_cleared?(@update_alarm)
    end

    test "a failed update is reported", context do
      exit_updater(context, {:shutdown, {:error, :closed}})

      assert_receive {:update_status, {:failed, message}}
      assert message =~ "Update failed"
      assert message =~ "closed"

      assert UpdateManager.status(context.manager) == :idle
      assert alarm_eventually_cleared?(@update_alarm)
    end

    test "a failed download is reported", context do
      exit_updater(context, {:shutdown, {:download_error, :max_disconnects_reached}})

      assert_receive {:update_status, {:failed, message}}
      assert message =~ "Download failed"
      assert message =~ "max_disconnects_reached"

      assert UpdateManager.status(context.manager) == :idle
      assert alarm_eventually_cleared?(@update_alarm)
    end

    test "a fwup failure is reported", context do
      exit_updater(context, {:shutdown, {:fwup_error, "Invalid signature"}})

      assert_receive {:update_status, {:failed, message}}
      assert message =~ "FWUP error"
      assert message =~ "Invalid signature"

      assert UpdateManager.status(context.manager) == :idle
      assert alarm_eventually_cleared?(@update_alarm)
    end

    test "an unexpected exit still releases the manager", context do
      exit_updater(context, :killed)

      assert_receive {:update_status, {:failed, message}}
      assert message =~ "Unexpected error"

      assert UpdateManager.status(context.manager) == :idle
      assert alarm_eventually_cleared?(@update_alarm)
    end

    test "the device is not rebooted after a failure", context do
      exit_updater(context, {:shutdown, {:fwup_error, "Invalid signature"}})

      assert_receive {:update_status, {:failed, _message}}
      refute_receive :reboot, 100
    end
  end

  describe "change_updater/2" do
    setup [:stub_client, :watch_socket]

    test "the next update is started by the new updater", context do
      manager = start_manager()

      :ok =
        UpdateManager.change_updater(manager, NervesHubLink.UpdateManagerTest.AlternateUpdater)

      # UpdaterMock has no expectations, so an update started by it would fail
      # verification. Only AlternateUpdater should be asked to start the update.
      assert UpdateManager.apply_update(manager, context.update_info, []) == :updating
    end
  end

  defp stub_client(_context) do
    test_pid = self()

    stub_with(ClientMock, NervesHubLink.ClientStub)

    stub(ClientMock, :reboot, fn ->
      send(test_pid, :reboot)
      :ok
    end)

    :ok
  end

  defp watch_socket(_context) do
    _ = start_supervised!({SocketStub, self()})
    {:ok, update_info: update_info()}
  end

  # Puts the manager into the `:updating` state with an updater pid the test
  # controls, so that updater exits can be simulated.
  defp start_update(_context) do
    updater_pid = start_supervised!({Agent, fn -> :updating end}, id: :fake_updater)

    expect(UpdaterMock, :start_update, fn _update_info, _fwup_config, _keys ->
      {:ok, updater_pid}
    end)

    manager = start_manager()

    update_info = update_info()

    assert UpdateManager.apply_update(manager, update_info, []) == :updating

    # Confirms the precondition for the tests that assert the alarm is cleared
    assert alarm_eventually_set?(@update_alarm)

    {:ok, manager: manager, updater_pid: updater_pid, update_info: update_info}
  end

  defp exit_updater(%{manager: manager, updater_pid: updater_pid}, reason) do
    send(manager, {:EXIT, updater_pid, reason})
  end

  defp start_manager(updater \\ UpdaterMock) do
    fwup_config = %FwupConfig{fwup_devpath: "/tmp/fwup_output", fwup_task: "upgrade"}

    start_supervised!(%{
      id: UpdateManager,
      start: {UpdateManager, :start_link, [{fwup_config, updater}]}
    })
  end

  defp update_info() do
    %UpdateInfo{
      firmware_url: URI.parse("http://localhost/test.fw"),
      firmware_meta: %FirmwareMetadata{uuid: "8a8b902c-d1a9-58aa-6111-04ab57c2f2a8"}
    }
  end

  # Alarms are global, so make sure a previous test's alarm has fully cleared
  # before this one starts, and leave the alarm clear on the way out.
  defp reset_update_alarm(_context) do
    on_exit(fn -> Alarms.clear_alarm(@update_alarm) end)

    Alarms.clear_alarm(@update_alarm)
    assert alarm_eventually_cleared?(@update_alarm)

    :ok
  end

  defp alarm_set?(alarm_id) do
    Enum.any?(Alarms.get_alarms(), &(elem(&1, 0) == alarm_id))
  end

  # Alarms are handled asynchronously, so a single read races with the manager
  defp alarm_eventually_set?(alarm_id), do: wait_until(fn -> alarm_set?(alarm_id) end)

  defp alarm_eventually_cleared?(alarm_id), do: wait_until(fn -> not alarm_set?(alarm_id) end)

  defp wait_until(fun, timeout \\ 500)
  defp wait_until(fun, timeout) when timeout <= 0, do: fun.()

  defp wait_until(fun, timeout) do
    if fun.() do
      true
    else
      Process.sleep(10)
      wait_until(fun, timeout - 10)
    end
  end
end
