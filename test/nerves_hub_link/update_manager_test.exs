defmodule NervesHubLink.UpdateManagerTest do
  use ExUnit.Case
  alias NervesHubLink.{FwupConfig, UpdateManager}
  alias NervesHubLink.Message.{FirmwareMetadata, UpdateInfo}
  alias NervesHubLink.Support.FWUPStreamPlug

  describe "fwup stream" do
    setup do
      port = 6000
      devpath = "/tmp/fwup_output"

      update_payload = %UpdateInfo{
        firmware_url: "http://localhost:#{port}/test.fw",
        firmware_meta: %FirmwareMetadata{}
      }

      {:ok, plug} =
        start_supervised(
          {Plug.Cowboy, scheme: :http, plug: FWUPStreamPlug, options: [port: port]}
        )

      File.rm(devpath)

      {:ok, [plug: plug, update_payload: update_payload, devpath: "/tmp/fwup_output"]}
    end

    test "apply", %{update_payload: update_payload, devpath: devpath} do
      fwup_config = %{default_config() | fwup_devpath: devpath}

      {:ok, manager} = UpdateManager.start_link(fwup_config)
      assert UpdateManager.apply_update(manager, update_payload) == {:updating, 0}

      assert_receive {:fwup, {:progress, 0}}
      assert_receive {:fwup, {:progress, 100}}
      assert_receive {:fwup, {:ok, 0, ""}}
    end

    test "reschedule", %{update_payload: update_payload, devpath: devpath} do
      test_pid = self()

      update_available_fun = fn _ ->
        case Process.get(:reschedule) do
          nil ->
            send(test_pid, :rescheduled)
            Process.put(:reschedule, true)
            {:reschedule, 50}

          _ ->
            :apply
        end
      end

      fwup_config = %{
        default_config()
        | fwup_devpath: devpath,
          update_available: update_available_fun
      }

      {:ok, manager} = UpdateManager.start_link(fwup_config)
      assert UpdateManager.apply_update(manager, update_payload) == :update_rescheduled
      assert_received :rescheduled
      refute_received {:fwup, _}

      assert_receive {:fwup, {:progress, 0}}, 250
      assert_receive {:fwup, {:progress, 100}}
      assert_receive {:fwup, {:ok, 0, ""}}
    end

    test "apply with fwup environment", %{update_payload: update_payload, devpath: devpath} do
      fwup_config = %{
        default_config()
        | fwup_devpath: devpath,
          fwup_task: "secret_upgrade",
          fwup_env: [
            {"SUPER_SECRET", "1234567890123456789012345678901234567890123456789012345678901234"}
          ]
      }

      # If setting SUPER_SECRET in the environment doesn't happen, then test fails
      # due to fwup getting a bad aes key.
      {:ok, manager} = UpdateManager.start_link(fwup_config)
      assert UpdateManager.apply_update(manager, update_payload) == {:updating, 0}

      assert_receive {:fwup, {:progress, 0}}
      assert_receive {:fwup, {:progress, 100}}
      assert_receive {:fwup, {:ok, 0, ""}}
    end
  end

  test "add fwup public key" do
    config = default_config()
    {:ok, manager} = start_supervised({UpdateManager, config})

    assert config.fwup_public_keys == :sys.get_state(manager).fwup_config.fwup_public_keys

    UpdateManager.add_fwup_public_key(manager, "test")
    keys = :sys.get_state(manager).fwup_config.fwup_public_keys
    refute config.fwup_public_keys == keys
    assert keys == ["test"]
  end

  test "remove fwup public key" do
    config = %{default_config() | fwup_public_keys: ["test"]}
    {:ok, manager} = start_supervised({UpdateManager, config})

    assert config.fwup_public_keys == :sys.get_state(manager).fwup_config.fwup_public_keys

    UpdateManager.remove_fwup_public_key(manager, "test")
    keys = :sys.get_state(manager).fwup_config.fwup_public_keys
    refute config.fwup_public_keys == keys
    assert keys == []
  end

  defp default_config() do
    test_pid = self()
    fwup_fun = &send(test_pid, {:fwup, &1})
    update_available_fun = fn _ -> :apply end

    %FwupConfig{
      handle_fwup_message: fwup_fun,
      update_available: update_available_fun
    }
  end
end
