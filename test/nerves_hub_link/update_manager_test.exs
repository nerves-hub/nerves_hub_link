defmodule NervesHubLink.UpdateManagerTest do
  use ExUnit.Case, async: false

  alias NervesHubLink.{FwupConfig, UpdateManager}
  alias NervesHubLink.Message.{FirmwareMetadata, UpdateInfo}
  alias NervesHubLink.Support.{FWUPStreamPlug, Utils}

  import Mock

  describe "fwup stream" do
    setup do
      port = Utils.unique_port_number()
      devpath = "/tmp/fwup_output"

      update_payload = %UpdateInfo{
        firmware_url: "http://localhost:#{port}/test.fw",
        firmware_meta: %FirmwareMetadata{}
      }

      {:ok, plug} =
        start_supervised(
          {Plug.Cowboy, scheme: :http, plug: FWUPStreamPlug, options: [port: port]}
        )

      {:ok, [plug: plug, update_payload: update_payload]}
    end

    @tag :tmp_dir
    test "apply", %{update_payload: update_payload, tmp_dir: tmp_dir} do
      fwup_config = %{default_config() | fwup_devpath: Path.join(tmp_dir, "fwup_output")}

      {:ok, manager} = UpdateManager.start_link(fwup_config)
      assert UpdateManager.apply_update(manager, update_payload, []) == {:updating, 0}

      assert_receive {:fwup, {:progress, 0}}
      assert_receive {:fwup, {:progress, 100}}
      assert_receive {:fwup, {:ok, 0, ""}}
    end

    @tag :tmp_dir
    test "reschedule", %{update_payload: update_payload, tmp_dir: tmp_dir} do
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
        | fwup_devpath: Path.join(tmp_dir, "fwup_output"),
          update_available: update_available_fun
      }

      {:ok, manager} = UpdateManager.start_link(fwup_config)
      assert UpdateManager.apply_update(manager, update_payload, []) == :update_rescheduled
      assert_received :rescheduled
      refute_received {:fwup, _}

      assert_receive {:fwup, {:progress, 0}}, 250
      assert_receive {:fwup, {:progress, 100}}
      assert_receive {:fwup, {:ok, 0, ""}}
    end

    @tag :tmp_dir
    test "apply with fwup environment", %{update_payload: update_payload, tmp_dir: tmp_dir} do
      fwup_config = %{
        default_config()
        | fwup_devpath: Path.join(tmp_dir, "fwup_output"),
          fwup_task: "secret_upgrade",
          fwup_env: [
            {"SUPER_SECRET", "1234567890123456789012345678901234567890123456789012345678901234"}
          ]
      }

      # If setting SUPER_SECRET in the environment doesn't happen, then test fails
      # due to fwup getting a bad aes key.
      {:ok, manager} = UpdateManager.start_link(fwup_config)
      assert UpdateManager.apply_update(manager, update_payload, []) == {:updating, 0}

      assert_receive {:fwup, {:progress, 0}}
      assert_receive {:fwup, {:progress, 100}}
      assert_receive {:fwup, {:ok, 0, ""}}
    end
  end

  describe "401 retry" do
    setup do
      port = 6543

      update_payload = %UpdateInfo{
        firmware_url: "http://localhost:#{port}/test.fw",
        firmware_meta: %FirmwareMetadata{}
      }

      {:ok, plug} =
        start_supervised(
          {Plug.Cowboy,
           scheme: :http,
           plug: {NervesHubLink.Support.HTTPUnauthorizedErrorPlug, report_pid: self()},
           options: [port: port]}
        )

      {:ok, [plug: plug, update_payload: update_payload]}
    end

    @tag :tmp_dir
    test "retries firmware updates once", %{
      update_payload: update_payload,
      tmp_dir: tmp_dir
    } do
      fwup_config = %{default_config() | fwup_devpath: Path.join(tmp_dir, "fwup_output")}

      {:ok, manager} = UpdateManager.start_link(fwup_config)

      with_mock NervesHubLink.Socket, check_update_available: fn -> update_payload end do
        assert UpdateManager.apply_update(manager, update_payload, []) == {:updating, 0}

        assert_receive {:fwup, {:progress, 0}}, 1_000
        assert_receive :request_error, 1_000
        assert_receive :request_error, 1_000

        assert UpdateManager.previous_update(manager) == :failed
      end
    end
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
