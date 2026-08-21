# SPDX-FileCopyrightText: 2026 Josh Kalderimis
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule NervesHubLink.SocketMessagesTest do
  @moduledoc """
  Drives `NervesHubLink.Socket` as if this test were the NervesHub server.

  `Slipstream.SocketTest` puts the test process in the place of the websocket
  connection, so messages can be pushed to the device and everything the device
  pushes back can be asserted on. That covers the device/server protocol and the
  routing of each message to its collaborator, neither of which was previously
  exercised.

  Note that pushes from the client block until the matching `assert_push`, so
  every push a test triggers has to be asserted.
  """

  use Slipstream.SocketTest

  import Mox

  alias NervesHubLink.ClientMock
  alias NervesHubLink.ClientStub
  alias NervesHubLink.Configurator.Config
  alias NervesHubLink.FwupConfig
  alias NervesHubLink.Message.UpdateInfo
  alias NervesHubLink.Socket
  alias NervesHubLink.UpdateManager
  alias NervesHubLink.UpdateManager.UpdaterMock

  @device_topic "device"
  @console_topic "console"

  @firmware_url "http://localhost:4000/firmware.fw"
  @uuid "8a8b902c-d1a9-58aa-6111-04ab57c2f2a8"

  setup :set_mox_global
  setup :verify_on_exit!

  setup context do
    test_pid = self()

    stub_with(ClientMock, ClientStub)

    # Optional callbacks aren't covered by ClientStub
    stub(ClientMock, :connected, fn -> :ok end)
    stub(ClientMock, :reconnect_backoff, fn -> [1_000] end)
    stub(ClientMock, :firmware_validated?, fn -> true end)
    stub(ClientMock, :firmware_auto_revert_detected?, fn -> false end)

    stub(ClientMock, :identify, fn ->
      send(test_pid, :identified)
      :ok
    end)

    stub(ClientMock, :handle_error, fn reason ->
      send(test_pid, {:handle_error, reason})
      :ok
    end)

    stub(ClientMock, :archive_available, fn info ->
      send(test_pid, {:archive_available, info})
      :ignore
    end)

    data_path = Path.join(System.tmp_dir!(), "socket_test_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(data_path) end)

    start_collaborators(data_path)

    socket = start_socket(data_path, Map.get(context, :socket_config, []))

    accept_connect(socket)

    {:ok, socket: socket, data_path: data_path}
  end

  describe "device messages" do
    test "an update message starts an update with the configured firmware keys", %{socket: socket} do
      test_pid = self()

      expect(UpdaterMock, :start_update, fn update_info, _fwup_config, fwup_public_keys ->
        send(test_pid, {:start_update, update_info, fwup_public_keys})
        {:ok, spawn(fn -> Process.sleep(:infinity) end)}
      end)

      push(socket, @device_topic, "update", update_payload())

      assert_receive {:start_update, %UpdateInfo{} = update_info, ["configured fwup key"]}
      assert URI.to_string(update_info.firmware_url) == @firmware_url
      assert update_info.firmware_meta.uuid == @uuid

      # a server too old to describe the firmware file itself
      assert update_info.size == nil
      assert update_info.checksum == nil
      assert update_info.partials_checksums == []
    end

    test "an update message carries the size and checksums of the firmware file",
         %{socket: socket} do
      test_pid = self()

      expect(UpdaterMock, :start_update, fn update_info, _fwup_config, _fwup_public_keys ->
        send(test_pid, {:start_update, update_info})
        {:ok, spawn(fn -> Process.sleep(:infinity) end)}
      end)

      payload =
        update_payload()
        |> Map.put("size", 2_097_152)
        |> Map.put("checksum", String.duplicate("A", 64))
        |> Map.put("partials_checksums", [String.duplicate("B", 64), String.duplicate("C", 64)])

      push(socket, @device_topic, "update", payload)

      assert_receive {:start_update, %UpdateInfo{} = update_info}
      assert update_info.size == 2_097_152
      assert update_info.checksum == String.duplicate("A", 64)

      assert update_info.partials_checksums == [
               String.duplicate("B", 64),
               String.duplicate("C", 64)
             ]
    end

    test "an update message that can not be parsed is ignored", %{socket: socket} do
      # UpdaterMock has no expectation, so starting an update would fail the test
      push(socket, @device_topic, "update", %{"firmware_url" => @firmware_url})

      assert Process.alive?(socket)
      refute_receive {:start_update, _, _}, 100
    end

    test "an archive message hands the parsed archive to the client", %{socket: socket} do
      push(socket, @device_topic, "archive", %{
        "url" => "http://localhost:4000/archive.fw",
        "uuid" => @uuid,
        "version" => "1.0.0"
      })

      assert_receive {:archive_available, archive_info}
      assert archive_info.uuid == @uuid
      assert archive_info.url == "http://localhost:4000/archive.fw"
    end

    test "an identify message calls the client", %{socket: socket} do
      push(socket, @device_topic, "identify", %{})

      assert_receive :identified
    end

    test "firmware public keys sent by the server are used for the next update", %{socket: socket} do
      test_pid = self()

      expect(UpdaterMock, :start_update, fn _update_info, _fwup_config, fwup_public_keys ->
        send(test_pid, {:start_update, fwup_public_keys})
        {:ok, spawn(fn -> Process.sleep(:infinity) end)}
      end)

      push(socket, @device_topic, "fwup_public_keys", %{"keys" => ["key from the server"]})
      push(socket, @device_topic, "update", update_payload())

      assert_receive {:start_update, ["key from the server"]}
    end

    test "archive public keys sent by the server replace the configured ones", %{socket: socket} do
      push(socket, @device_topic, "archive_public_keys", %{"keys" => ["archive key from server"]})

      # Round-trip a call so the message above has been handled
      assert NervesHubLink.socket_connected?(socket)

      assert :sys.get_state(socket).assigns.config.archive_public_keys == [
               "archive key from server"
             ]
    end

    test "an empty key list from the server does not clear the configured firmware keys", %{
      socket: socket
    } do
      # NervesHub supplies the firmware as well as the keys that verify it, so a
      # server that sends no keys must not be able to disable signature checking.
      push(socket, @device_topic, "fwup_public_keys", %{"keys" => []})

      assert NervesHubLink.socket_connected?(socket)

      assert :sys.get_state(socket).assigns.config.fwup_public_keys == ["configured fwup key"]
    end

    test "an empty key list from the server does not clear the configured archive keys", %{
      socket: socket
    } do
      push(socket, @device_topic, "archive_public_keys", %{"keys" => []})

      assert NervesHubLink.socket_connected?(socket)

      assert :sys.get_state(socket).assigns.config.archive_public_keys == [
               "configured archive key"
             ]
    end

    test "keys from the server that are not binaries are discarded", %{socket: socket} do
      push(socket, @device_topic, "fwup_public_keys", %{"keys" => [nil, 42]})

      assert NervesHubLink.socket_connected?(socket)

      assert :sys.get_state(socket).assigns.config.fwup_public_keys == ["configured fwup key"]
    end

    test "an extensions:get message asks to join the extensions topic", %{socket: socket} do
      push(socket, @device_topic, "extensions:get", %{})

      assert_join("extensions", available_extensions, :error)

      assert is_map(available_extensions)
      assert Map.has_key?(available_extensions, "health")
    end

    test "a join reply that doesn't name extensions doesn't take the socket down", %{
      socket: socket
    } do
      push(socket, @device_topic, "extensions:get", %{})

      # An `:ok` reply carries `%{}`, which is not the list of extension names
      # the attach path is expecting
      assert_join("extensions", _available_extensions, :ok)

      assert NervesHubLink.socket_connected?(socket)
      assert Process.alive?(socket)
    end

    test "an unknown message is ignored", %{socket: socket} do
      push(socket, @device_topic, "who_knows", %{})

      assert NervesHubLink.socket_connected?(socket)
      assert Process.alive?(socket)
    end
  end

  describe "reporting update status" do
    setup :join_device_topic

    test "download progress is pushed as fwup_progress", %{socket: socket} do
      NervesHubLink.send_update_status(socket, {:downloading, 42})

      assert_push(@device_topic, "fwup_progress", %{stage: :downloading, value: 42})
    end

    test "update progress is pushed as fwup_progress", %{socket: socket} do
      NervesHubLink.send_update_status(socket, {:updating, 99})

      assert_push(@device_topic, "fwup_progress", %{stage: :updating, value: 99})
    end

    test "a received update is pushed as a status update", %{socket: socket} do
      NervesHubLink.send_update_status(socket, :received)

      assert_push(@device_topic, "status_update", %{status: :received})
    end

    test "a started download reports the network interface", %{socket: socket} do
      NervesHubLink.send_update_status(socket, {:started, "eth0"})

      assert_push(@device_topic, "status_update", %{
        status: :started,
        downloader_network_interface: "eth0"
      })
    end

    test "a completed update also sends a final 100% progress message", %{socket: socket} do
      NervesHubLink.send_update_status(socket, :completed)

      # Older versions of NervesHub rely on this final progress message
      assert_push(@device_topic, "fwup_progress", %{stage: :updating, value: 100})
      assert_push(@device_topic, "status_update", %{status: :completed})
    end

    test "an ignored update reports the reason", %{socket: socket} do
      NervesHubLink.send_update_status(socket, {:ignored, "on battery"})

      assert_push(@device_topic, "status_update", %{status: :ignored, reason: "on battery"})
    end

    test "a rescheduled update reports the delay", %{socket: socket} do
      NervesHubLink.send_update_status(socket, {:reschedule, 15})

      assert_push(@device_topic, "status_update", %{status: :rescheduled, delay_for: 15})
    end

    test "a rescheduled update reports the delay and reason", %{socket: socket} do
      NervesHubLink.send_update_status(socket, {:reschedule, 15, "busy"})

      assert_push(@device_topic, "status_update", %{
        status: :rescheduled,
        delay_for: 15,
        reason: "busy"
      })
    end

    test "a failed update reports the reason", %{socket: socket} do
      NervesHubLink.send_update_status(socket, {:failed, "FWUP error : bad signature"})

      assert_push(@device_topic, "status_update", %{
        status: :failed,
        reason: "FWUP error : bad signature"
      })
    end
  end

  describe "running support scripts" do
    setup :join_device_topic

    test "the script output and return value are sent back", %{socket: socket} do
      push(socket, @device_topic, "scripts/run", %{
        "ref" => "script-1",
        "text" => ~s|IO.puts("working"); 6 * 7|,
        "timeout" => 5_000
      })

      assert_push(@device_topic, "scripts/run", %{
        ref: "script-1",
        result: "completed",
        output: output,
        return: "42"
      })

      assert output =~ "working"
    end

    test "a script that runs too long is killed and reported", %{socket: socket} do
      push(socket, @device_topic, "scripts/run", %{
        "ref" => "script-2",
        "text" => "Process.sleep(:infinity)",
        "timeout" => 50
      })

      assert_push(@device_topic, "scripts/run", %{
        ref: "script-2",
        result: "error",
        reason: "timeout"
      })
    end

    test "a script that raises reports the error in its output", %{socket: socket} do
      push(socket, @device_topic, "scripts/run", %{
        "ref" => "script-3",
        "text" => ~s|raise "boom"|,
        "timeout" => 5_000
      })

      assert_push(@device_topic, "scripts/run", %{ref: "script-3", output: output})

      assert output =~ "boom"
    end
  end

  describe "receiving a file over the console" do
    test "the file is written to the data path", %{socket: socket, data_path: data_path} do
      filename = "notes.txt"

      push(socket, @console_topic, "file-data/start", %{"filename" => filename})
      push(socket, @console_topic, "file-data", file_chunk(filename, "hello "))
      push(socket, @console_topic, "file-data", file_chunk(filename, "world"))
      push(socket, @console_topic, "file-data/stop", %{"filename" => filename})

      # A call round-trips, so every message above has been handled by now
      assert NervesHubLink.socket_connected?(socket)

      assert File.read!(Path.join(data_path, filename)) == "hello world"
    end

    test "a console message starts a console session", %{socket: socket} do
      refute NervesHubLink.console_active?(socket)

      push(socket, @console_topic, "file-data/start", %{"filename" => "notes.txt"})

      assert NervesHubLink.console_active?(socket)
    end
  end

  describe "sending a file to the console" do
    @describetag socket_config: [remote_iex: true]

    setup :join_console_topic

    test "the file is uploaded in chunks", %{socket: socket} do
      path = Path.join(System.tmp_dir!(), "upload_#{System.unique_integer([:positive])}.txt")
      File.write!(path, "hello from the device")
      on_exit(fn -> File.rm(path) end)

      filename = Path.basename(path)

      assert NervesHubLink.send_file(socket, path) == :ok

      assert_push(@console_topic, "file-data/start", %{filename: ^filename})
      assert_push(@console_topic, "file-data", %{filename: ^filename, chunk: 0, data: data})
      assert_push(@console_topic, "file-data/stop", %{filename: ^filename})

      assert Base.decode64!(data) == "hello from the device"
    end

    test "a file that is too large is rejected", %{socket: socket} do
      path = Path.join(System.tmp_dir!(), "too_big_#{System.unique_integer([:positive])}")
      # Sparse file, so this doesn't actually write 10MB
      {:ok, fd} = :file.open(path, [:write, :raw])
      :ok = :file.pwrite(fd, 10_485_760, <<0>>)
      :ok = :file.close(fd)
      on_exit(fn -> File.rm(path) end)

      assert NervesHubLink.send_file(socket, path) == {:error, :too_large}
    end

    test "a missing file is reported", %{socket: socket} do
      assert NervesHubLink.send_file(socket, "/definitely/not/a/file") == {:error, :enoent}
    end
  end

  describe "connection status" do
    test "the socket reports being connected before any topic is joined", %{socket: socket} do
      assert NervesHubLink.socket_connected?(socket)

      refute NervesHubLink.connected?(socket)
      refute NervesHubLink.console_connected?(socket)
      refute NervesHubLink.extensions_connected?(socket)
    end

    test "the device topic is reported as joined once it joins", %{socket: socket} = context do
      :ok = join_device_topic(context)

      assert NervesHubLink.connected?(socket)
      assert NervesHubLink.socket_connected?(socket)
    end

    test "no console session is active until the console is used", %{socket: socket} do
      refute NervesHubLink.console_active?(socket)
    end
  end

  describe "a reboot request" do
    setup :join_device_topic

    test "tells NervesHub and reboots through the client", %{socket: socket} do
      test_pid = self()

      stub(ClientMock, :reboot, fn ->
        send(test_pid, :reboot)
        :ok
      end)

      push(socket, @device_topic, "reboot", %{})

      assert_push(@device_topic, "rebooting", %{})
      assert_receive :reboot
    end
  end

  describe "joining topics" do
    @describetag socket_config: [
                   remote_iex: true,
                   params: %{
                     "console_version" => "2.0.0",
                     "device_api_version" => "2.3.0",
                     "nerves_fw_uuid" => "8a8b902c-d1a9-58aa-6111-04ab57c2f2a8",
                     "nerves_fw_version" => "1.0.0",
                     "serial_number" => "test-device"
                   }
                 ]

    test "the device join describes the device and its firmware" do
      assert_join(@device_topic, params, :error)

      assert params["device_api_version"] == "2.3.0"
      assert params["nerves_fw_uuid"] == "8a8b902c-d1a9-58aa-6111-04ab57c2f2a8"
      assert params["serial_number"] == "test-device"
      assert params["currently_downloading_uuid"] == nil
      assert %{"firmware_validated" => true} = params["meta"]
    end

    test "the console join carries only the protocol versions" do
      assert_join(@console_topic, params, :error)

      assert params == %{"console_version" => "2.0.0", "device_api_version" => "2.3.0"}
    end
  end

  describe "reporting the network interface" do
    # Joining the device topic makes the client inspect the connection process
    # with `:sys.get_state/2`. Under test that process is this one, which
    # doesn't speak the sys protocol - the same position the client is in when
    # the real connection process is busy or has died.

    test "a connection process that never answers doesn't take the socket down", %{socket: socket} do
      assert_join(@device_topic, _params, :ok)

      # Take the probe out of the mailbox and leave it unanswered, so the client
      # is definitely waiting on it
      assert_receive {:system, _from, _request}, 1_000

      # This call queues behind the probe, so it only returns once the client
      # has given up on it
      assert NervesHubLink.socket_connected?(socket)
      assert Process.alive?(socket)
    end

    test "an unexpected answer doesn't take the socket down", %{socket: socket} do
      assert_join(@device_topic, _params, :ok)

      receive do
        {:system, from, _request} -> GenServer.reply(from, :not_a_valid_sys_reply)
      after
        1_000 -> flunk("expected the client to ask for the connection state")
      end

      assert NervesHubLink.socket_connected?(socket)
      assert Process.alive?(socket)
    end
  end

  describe "disconnecting" do
    test "the client is told about the error and the alarm is raised", %{socket: socket} do
      disconnect(socket, :heartbeat_timeout)

      assert_receive {:handle_error, :heartbeat_timeout}
      assert alarm_eventually_set?(NervesHubLink.Disconnected)
      assert Process.alive?(socket)
    end
  end

  # A topic has to be joined before the client will push to it.
  defp join_device_topic(%{socket: _socket}) do
    assert_join(@device_topic, _params, :ok)
    answer_network_interface_probe()
    :ok
  end

  defp join_console_topic(%{socket: _socket}) do
    assert_join(@console_topic, _params, :ok)
    :ok
  end

  # Joining the device topic makes the client work out which network interface
  # it connected over by calling `:sys.get_state/1` on the connection process.
  # Under `Slipstream.SocketTest` that process is this test, which doesn't speak
  # the sys protocol, so answer the probe with something the client discards
  # (it logs and retries later). Left unanswered, the client would block for the
  # full 5s `:sys.get_state/1` timeout and then crash.
  defp answer_network_interface_probe(timeout \\ 1_000) do
    receive do
      # `{:ok, state}` is the reply shape `:sys.get_state/1` expects. The state
      # itself is deliberately not a `%{conn: _}`, so the client falls through
      # to its "couldn't determine the interface" branch.
      {:system, from, _request} -> GenServer.reply(from, {:ok, :no_connection_information})
    after
      timeout -> :ok
    end
  end

  defp start_collaborators(data_path) do
    _ = start_supervised!({DynamicSupervisor, name: NervesHubLink.ExtensionsSupervisor})
    _ = start_supervised!(NervesHubLink.Extensions)

    _ =
      start_supervised!(%{
        id: UpdateManager,
        start:
          {UpdateManager, :start_link,
           [
             {%FwupConfig{fwup_devpath: "/tmp/fwup_output", fwup_task: "upgrade"}, UpdaterMock},
             [name: UpdateManager]
           ]}
      })

    _ =
      start_supervised!(%{
        id: NervesHubLink.ArchiveManager,
        start:
          {NervesHubLink.ArchiveManager, :start_link,
           [%{data_path: data_path}, [name: NervesHubLink.ArchiveManager]]}
      })

    _ = start_supervised!({Task.Supervisor, name: SupportScriptsTaskSupervisor})
    _ = start_supervised!(NervesHubLink.SupportScriptsManager)

    :ok
  end

  defp start_socket(data_path, overrides) do
    config =
      struct(
        %Config{
          archive_public_keys: ["configured archive key"],
          compress: false,
          connect_wait_for_network: false,
          data_path: data_path,
          fwup_public_keys: ["configured fwup key"],
          heartbeat_interval_msec: 30_000,
          params: %{"device_api_version" => "2.3.0"},
          rejoin_after: [1_000],
          remote_iex: false,
          remote_iex_timeout: 300,
          socket: [
            url: URI.parse("ws://localhost:4000/socket/websocket"),
            reconnect_after_msec: [1_000],
            test_mode?: true
          ],
          ssl: []
        },
        overrides
      )

    start_supervised!(%{
      id: Socket,
      start: {Socket, :start_link, [config, [name: Socket]]}
    })
  end

  defp file_chunk(filename, data) do
    %{"filename" => filename, "data" => Base.encode64(data)}
  end

  defp update_payload() do
    %{
      "firmware_url" => @firmware_url,
      "firmware_meta" => %{
        "uuid" => @uuid,
        "product" => "test",
        "version" => "1.0.0",
        "platform" => "host",
        "architecture" => "x86_64"
      }
    }
  end

  defp alarm_eventually_set?(alarm_id, timeout \\ 500)
  defp alarm_eventually_set?(alarm_id, timeout) when timeout <= 0, do: alarm_set?(alarm_id)

  defp alarm_eventually_set?(alarm_id, timeout) do
    if alarm_set?(alarm_id) do
      true
    else
      Process.sleep(10)
      alarm_eventually_set?(alarm_id, timeout - 10)
    end
  end

  defp alarm_set?(alarm_id) do
    Enum.any?(NervesHubLink.Alarms.get_alarms(), &(elem(&1, 0) == alarm_id))
  end
end
