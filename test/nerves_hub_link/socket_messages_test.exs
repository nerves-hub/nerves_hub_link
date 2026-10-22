# SPDX-FileCopyrightText: 2026 Josh Kalderimis
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule NervesHubLink.SocketMessagesTest do
  @moduledoc """
  Drives `NervesHubLink.Socket` as if this test were the NervesHub server.

  The socket connects over a real websocket to a server in this test, so what
  is covered here is the device's half of the protocol as it goes over the
  wire, and the routing of each message to its collaborator.

  Payloads are therefore what JSON carries: a map the device builds with atom
  keys is asserted on here with string keys and string values.
  """

  use ExUnit.Case, async: false
  use NervesHubLink.Support.SocketHarness

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

    await_connected(socket)

    {:ok, socket: socket, data_path: data_path}
  end

  describe "update mode" do
    setup :join_device_topic

    test "the mode NervesHub reports is what update_mode/1 answers", %{socket: socket} do
      assert Socket.update_mode(socket) == nil
      refute Socket.managed_updates_allowed?(socket)

      server_push(@device_topic, "update_mode", %{
        "mode" => "device_managed",
        "managed_updates_allowed" => true
      })

      assert_eventually(Socket.update_mode(socket) == :device_managed)
      assert Socket.managed_updates_allowed?(socket)
    end

    test "a mode this version does not know is ignored rather than stored", %{socket: socket} do
      server_push(@device_topic, "update_mode", %{
        "mode" => "whenever",
        "managed_updates_allowed" => false
      })

      # A future NervesHub adding a mode must not leave an old device holding a
      # value it cannot reason about.
      assert Socket.update_mode(socket) == nil
    end

    test "setting the mode is answered by NervesHub's report of it", %{socket: socket} do
      task = Task.async(fn -> Socket.set_update_mode(socket, :device_managed) end)

      assert_push(@device_topic, "set_update_mode", %{"mode" => "device_managed"})

      server_push(@device_topic, "update_mode", %{
        "mode" => "device_managed",
        "managed_updates_allowed" => true
      })

      assert Task.await(task) == :ok
      assert Socket.update_mode(socket) == :device_managed
    end

    test "a refused change reports why, and the mode NervesHub still has", %{socket: socket} do
      task = Task.async(fn -> Socket.set_update_mode(socket, :device_managed) end)

      assert_push(@device_topic, "set_update_mode", %{"mode" => "device_managed"})

      server_push(@device_topic, "update_mode", %{
        "mode" => "automatic",
        "managed_updates_allowed" => false,
        "error" => "not_permitted"
      })

      assert Task.await(task) == {:error, :not_permitted}
      assert Socket.update_mode(socket) == :automatic
    end
  end

  describe "device initiated updates" do
    setup :join_device_topic

    test "check_for_update reports what NervesHub has waiting", %{socket: socket} do
      task = Task.async(fn -> Socket.check_for_update(socket) end)

      assert_push(@device_topic, "check_update", %{})

      server_push(@device_topic, "update_available", %{
        "available" => true,
        "firmware_meta" => %{"version" => "1.2.0"}
      })

      assert {:ok, %{available?: true, firmware_meta: %{"version" => "1.2.0"}}} = Task.await(task)
    end

    test "check_for_update reports nothing waiting", %{socket: socket} do
      task = Task.async(fn -> Socket.check_for_update(socket) end)

      assert_push(@device_topic, "check_update", %{})

      server_push(@device_topic, "update_available", %{
        "available" => false,
        "firmware_meta" => nil
      })

      assert {:ok, %{available?: false, firmware_meta: nil}} = Task.await(task)
    end

    test "start_update is answered by the update message itself", %{socket: socket} do
      test_pid = self()

      expect(UpdaterMock, :start_update, fn update_info, _fwup_config, _keys ->
        send(test_pid, {:start_update, update_info})
        {:ok, spawn(fn -> Process.sleep(:infinity) end)}
      end)

      task = Task.async(fn -> Socket.start_update(socket) end)

      assert_push(@device_topic, "request_update", %{})

      # NervesHub answers a request with the same "update" message a deployment
      # group sends, so nothing new applies the firmware.
      server_push(@device_topic, "update", update_payload())

      assert Task.await(task) == :ok
      assert_receive {:start_update, %UpdateInfo{}}

      # Applying an update reports itself, and every push has to be asserted or
      # the socket blocks on it.
      assert_push(@device_topic, "status_update", %{"status" => "received"})
    end

    test "a refused request reports how long to wait", %{socket: socket} do
      task = Task.async(fn -> Socket.start_update(socket) end)

      assert_push(@device_topic, "request_update", %{})

      server_push(@device_topic, "update_rejected", %{"reason" => "busy", "delay_for" => 5})

      assert Task.await(task) == {:error, {:busy, 5}}
    end

    test "a request refused for a reason this version does not know still resolves", %{
      socket: socket
    } do
      task = Task.async(fn -> Socket.start_update(socket) end)

      assert_push(@device_topic, "request_update", %{})

      server_push(@device_topic, "update_rejected", %{"reason" => "some_future_reason"})

      # The caller must never be left parked on a reason we cannot name.
      assert Task.await(task) == {:error, :error}
    end

    test "start_update is refused locally while an update is already running", %{socket: socket} do
      expect(UpdaterMock, :start_update, fn _update_info, _fwup_config, _keys ->
        {:ok, spawn(fn -> Process.sleep(:infinity) end)}
      end)

      server_push(@device_topic, "update", update_payload())

      # The update is applied before this is pushed, so asserting it is also how
      # the test knows UpdateManager has been told.
      assert_push(@device_topic, "status_update", %{"status" => "received"})
      assert UpdateManager.status() == :updating

      # Asking for another firmware URL would only waste a deployment slot.
      assert Socket.start_update(socket) == {:error, :updating}
    end
  end

  describe "device messages" do
    test "an update message starts an update with the configured firmware keys" do
      test_pid = self()

      expect(UpdaterMock, :start_update, fn update_info, _fwup_config, fwup_public_keys ->
        send(test_pid, {:start_update, update_info, fwup_public_keys})
        {:ok, spawn(fn -> Process.sleep(:infinity) end)}
      end)

      server_push(@device_topic, "update", update_payload())

      assert_receive {:start_update, %UpdateInfo{} = update_info, ["configured fwup key"]}
      assert URI.to_string(update_info.firmware_url) == @firmware_url
      assert update_info.firmware_meta.uuid == @uuid

      # a server too old to describe the firmware file itself
      assert update_info.size == nil
      assert update_info.checksum == nil
      assert update_info.partials_checksums == []
    end

    test "an update message carries the size and checksums of the firmware file",
         _context do
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

      server_push(@device_topic, "update", payload)

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
      server_push(@device_topic, "update", %{"firmware_url" => @firmware_url})

      assert Process.alive?(socket)
      refute_receive {:start_update, _, _}, 100
    end

    test "an archive message hands the parsed archive to the client" do
      server_push(@device_topic, "archive", %{
        "url" => "http://localhost:4000/archive.fw",
        "uuid" => @uuid,
        "version" => "1.0.0"
      })

      assert_receive {:archive_available, archive_info}
      assert archive_info.uuid == @uuid
      assert archive_info.url == "http://localhost:4000/archive.fw"
    end

    test "an identify message calls the client" do
      server_push(@device_topic, "identify", %{})

      assert_receive :identified
    end

    test "firmware public keys sent by the server are used for the next update" do
      test_pid = self()

      expect(UpdaterMock, :start_update, fn _update_info, _fwup_config, fwup_public_keys ->
        send(test_pid, {:start_update, fwup_public_keys})
        {:ok, spawn(fn -> Process.sleep(:infinity) end)}
      end)

      server_push(@device_topic, "fwup_public_keys", %{"keys" => ["key from the server"]})
      server_push(@device_topic, "update", update_payload())

      assert_receive {:start_update, ["key from the server"]}
    end

    test "archive public keys sent by the server replace the configured ones", %{socket: socket} do
      server_push(@device_topic, "archive_public_keys", %{"keys" => ["archive key from server"]})

      assert_eventually(
        :sys.get_state(socket).config.archive_public_keys == [
          "archive key from server"
        ]
      )
    end

    test "an empty key list from the server does not clear the configured firmware keys", %{
      socket: socket
    } do
      # NervesHub supplies the firmware as well as the keys that verify it, so a
      # server that sends no keys must not be able to disable signature checking.
      server_push(@device_topic, "fwup_public_keys", %{"keys" => []})
      assert_handled_in_order()

      assert :sys.get_state(socket).config.fwup_public_keys == ["configured fwup key"]
    end

    test "an empty key list from the server does not clear the configured archive keys", %{
      socket: socket
    } do
      server_push(@device_topic, "archive_public_keys", %{"keys" => []})
      assert_handled_in_order()

      assert :sys.get_state(socket).config.archive_public_keys == [
               "configured archive key"
             ]
    end

    test "keys from the server that are not binaries are discarded", %{socket: socket} do
      server_push(@device_topic, "fwup_public_keys", %{"keys" => [nil, 42]})

      assert NervesHubLink.socket_connected?(socket)

      assert :sys.get_state(socket).config.fwup_public_keys == ["configured fwup key"]
    end

    test "an extensions:get message asks to join the extensions topic" do
      server_push(@device_topic, "extensions:get", %{})

      assert_join("extensions", available_extensions, :error)

      assert is_map(available_extensions)
      assert Map.has_key?(available_extensions, "health")
    end

    test "only the extensions the platform advertised are offered" do
      # The platform names what it has and at which versions, so this device
      # never declares a version nothing can serve, and never declares an
      # extension an operator switched off.
      server_push(@device_topic, "extensions:get", %{
        "extensions" => %{"health" => ["0.0.1"]}
      })

      assert_join("extensions", offered, :error)

      assert offered == %{"health" => "0.0.1"}
    end

    test "an extension the platform has at another version is not offered" do
      server_push(@device_topic, "extensions:get", %{
        "extensions" => %{"health" => ["9.0.0"], "geo" => ["0.0.1"]}
      })

      assert_join("extensions", offered, :error)

      assert offered == %{"geo" => "0.0.1"}
    end

    test "a join reply that doesn't name extensions doesn't take the socket down", %{
      socket: socket
    } do
      server_push(@device_topic, "extensions:get", %{})

      # An `:ok` reply carries `%{}`, which is not the list of extension names
      # the attach path is expecting
      assert_join("extensions", _available_extensions, :ok)

      assert NervesHubLink.socket_connected?(socket)
      assert Process.alive?(socket)
    end

    test "an unknown message is ignored", %{socket: socket} do
      server_push(@device_topic, "who_knows", %{})
      assert_handled_in_order()

      assert NervesHubLink.socket_connected?(socket)
      assert Process.alive?(socket)
    end
  end

  describe "reporting update status" do
    setup :join_device_topic

    test "download progress is pushed as fwup_progress", %{socket: socket} do
      NervesHubLink.send_update_status(socket, {:downloading, 42})

      assert_push(@device_topic, "fwup_progress", %{"stage" => "downloading", "value" => 42})
    end

    test "update progress is pushed as fwup_progress", %{socket: socket} do
      NervesHubLink.send_update_status(socket, {:updating, 99})

      assert_push(@device_topic, "fwup_progress", %{"stage" => "updating", "value" => 99})
    end

    test "a received update is pushed as a status update", %{socket: socket} do
      NervesHubLink.send_update_status(socket, :received)

      assert_push(@device_topic, "status_update", %{"status" => "received"})
    end

    test "a started download reports the network interface", %{socket: socket} do
      NervesHubLink.send_update_status(socket, {:started, "eth0"})

      assert_push(@device_topic, "status_update", %{
        "status" => "started",
        "downloader_network_interface" => "eth0"
      })
    end

    test "a completed update also sends a final 100% progress message", %{socket: socket} do
      NervesHubLink.send_update_status(socket, :completed)

      # Older versions of NervesHub rely on this final progress message
      assert_push(@device_topic, "fwup_progress", %{"stage" => "updating", "value" => 100})
      assert_push(@device_topic, "status_update", %{"status" => "completed"})
    end

    test "an ignored update reports the reason", %{socket: socket} do
      NervesHubLink.send_update_status(socket, {:ignored, "on battery"})

      assert_push(@device_topic, "status_update", %{
        "status" => "ignored",
        "reason" => "on battery"
      })
    end

    test "a rescheduled update reports the delay", %{socket: socket} do
      NervesHubLink.send_update_status(socket, {:reschedule, 15})

      assert_push(@device_topic, "status_update", %{"status" => "rescheduled", "delay_for" => 15})
    end

    test "a rescheduled update reports the delay and reason", %{socket: socket} do
      NervesHubLink.send_update_status(socket, {:reschedule, 15, "busy"})

      assert_push(@device_topic, "status_update", %{
        "status" => "rescheduled",
        "delay_for" => 15,
        "reason" => "busy"
      })
    end

    test "a failed update reports the reason", %{socket: socket} do
      NervesHubLink.send_update_status(socket, {:failed, "FWUP error : bad signature"})

      assert_push(@device_topic, "status_update", %{
        "status" => "failed",
        "reason" => "FWUP error : bad signature"
      })
    end
  end

  describe "running support scripts" do
    setup :join_device_topic

    test "the script output and return value are sent back" do
      server_push(@device_topic, "scripts/run", %{
        "ref" => "script-1",
        "text" => ~s|IO.puts("working"); 6 * 7|,
        "timeout" => 5_000
      })

      assert_push(@device_topic, "scripts/run", %{
        "ref" => "script-1",
        "result" => "completed",
        "output" => output,
        "return" => "42"
      })

      assert output =~ "working"
    end

    test "a script that runs too long is killed and reported" do
      server_push(@device_topic, "scripts/run", %{
        "ref" => "script-2",
        "text" => "Process.sleep(:infinity)",
        "timeout" => 50
      })

      assert_push(@device_topic, "scripts/run", %{
        "ref" => "script-2",
        "result" => "error",
        "reason" => "timeout"
      })
    end

    test "a script that raises reports the error in its output" do
      server_push(@device_topic, "scripts/run", %{
        "ref" => "script-3",
        "text" => ~s|raise "boom"|,
        "timeout" => 5_000
      })

      assert_push(@device_topic, "scripts/run", %{"ref" => "script-3", "output" => output})

      assert output =~ "boom"
    end
  end

  describe "receiving a file over the console" do
    test "the file is written to the data path", %{data_path: data_path} do
      filename = "notes.txt"

      server_push(@console_topic, "file-data/start", %{"filename" => filename})
      server_push(@console_topic, "file-data", file_chunk(filename, "hello "))
      server_push(@console_topic, "file-data", file_chunk(filename, "world"))
      server_push(@console_topic, "file-data/stop", %{"filename" => filename})

      assert_eventually(File.read(Path.join(data_path, filename)) == {:ok, "hello world"})
    end

    test "a console message starts a console session", %{socket: socket} do
      refute NervesHubLink.console_active?(socket)

      server_push(@console_topic, "file-data/start", %{"filename" => "notes.txt"})

      assert_eventually(NervesHubLink.console_active?(socket))
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

      assert_push(@console_topic, "file-data/start", %{"filename" => ^filename})

      assert_push(@console_topic, "file-data", %{
        "filename" => ^filename,
        "chunk" => 0,
        "data" => data
      })

      assert_push(@console_topic, "file-data/stop", %{"filename" => ^filename})

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

    test "tells NervesHub and reboots through the client" do
      test_pid = self()

      stub(ClientMock, :reboot, fn ->
        send(test_pid, :reboot)
        :ok
      end)

      server_push(@device_topic, "reboot", %{})

      assert_push(@device_topic, "rebooting", %{})
      assert_receive :reboot
    end
  end

  describe "joining topics" do
    @describetag socket_config: [
                   remote_iex: true,
                   params: %{
                     "console_version" => "2.0.0",
                     "device_api_version" => "2.4.0",
                     "nerves_fw_uuid" => "8a8b902c-d1a9-58aa-6111-04ab57c2f2a8",
                     "nerves_fw_version" => "1.0.0",
                     "serial_number" => "test-device"
                   }
                 ]

    test "the device join describes the device and its firmware" do
      assert_join(@device_topic, params, :error)

      assert params["device_api_version"] == "2.4.0"
      assert params["nerves_fw_uuid"] == "8a8b902c-d1a9-58aa-6111-04ab57c2f2a8"
      assert params["serial_number"] == "test-device"
      assert params["currently_downloading_uuid"] == nil
      assert %{"firmware_validated" => true} = params["meta"]
    end

    test "the console join carries only the protocol versions" do
      assert_join(@console_topic, params, :error)

      assert params == %{"console_version" => "2.0.0", "device_api_version" => "2.4.0"}
    end
  end

  describe "reporting the network interface" do
    # The connection is held by the socket itself, so the interface is a plain
    # read rather than the look into another process's state it used to be.
    test "the interface the connection is using is reported after joining", %{socket: socket} do
      assert_join(@device_topic, _params, :ok)

      assert_push(@device_topic, "report_network_interface", %{"interface" => interface})

      assert is_binary(interface)
      assert Process.alive?(socket)
    end
  end

  describe "recovering" do
    setup :join_device_topic

    # The whole point of the library: after losing the connection it comes
    # back, and joins again.
    test "the device reconnects and rejoins after the server closes", %{socket: socket} do
      server_close()

      assert_receive {:handle_error, :closed_by_remote}

      assert_join(@device_topic, _params, :ok)
      await_joined(socket, :device)

      assert NervesHubLink.connected?(socket)
    end

    test "a topic closed with an error is joined again, keeping the connection", %{socket: socket} do
      join_ref = :sys.get_state(socket).connection.joins[@device_topic].ref

      server_push(@device_topic, "phx_error", %{}, ref: join_ref, join_ref: join_ref)

      assert_receive {:handle_error, {:error, %{}}}

      assert_join(@device_topic, _params, :ok)
      await_joined(socket, :device)

      assert NervesHubLink.socket_connected?(socket)
    end

    # Phoenix sends `phx_close` whenever a channel terminates normally, so a
    # graceful shutdown on NervesHub's side arrives this way rather than as an
    # error. Left alone, the device sits on a healthy connection with no
    # device channel - taking no updates and reporting no status, while
    # looking connected - and nothing recovers it, because there is no
    # disconnect to trigger a reconnect.
    test "a topic the server closes normally is joined again", %{socket: socket} do
      join_ref = :sys.get_state(socket).connection.joins[@device_topic].ref

      server_push(@device_topic, "phx_close", %{}, ref: join_ref, join_ref: join_ref)

      assert_join(@device_topic, _params, :ok)
      await_joined(socket, :device)

      assert Process.alive?(socket)
      assert NervesHubLink.socket_connected?(socket)
      assert NervesHubLink.connected?(socket)
    end
  end

  describe "replies to the device's own pushes" do
    setup :join_device_topic

    # Phoenix sends a reply whenever a channel returns `{:reply, ...}`, so any
    # of these pushes can be answered. Only the extensions detach means
    # anything here, and the rest used to take the socket down.
    test "an ok reply is ignored rather than fatal", %{socket: socket} do
      NervesHubLink.send_update_status(socket, :received)

      message = assert_push(@device_topic, "status_update", %{"status" => "received"})
      server_reply(message, "ok")
      assert_handled_in_order()

      assert NervesHubLink.socket_connected?(socket)
      assert Process.alive?(socket)
    end

    test "a reply with a status this version does not know is ignored too", %{socket: socket} do
      NervesHubLink.send_update_status(socket, :received)

      message = assert_push(@device_topic, "status_update", %{"status" => "received"})
      server_reply(message, "accepted", %{"queued" => true})
      assert_handled_in_order()

      assert NervesHubLink.socket_connected?(socket)
      assert Process.alive?(socket)
    end
  end

  describe "disconnecting" do
    setup :join_device_topic

    # Nothing can answer a parked request once the connection has gone, and
    # waiting out the 30s timeout would report it as a timeout rather than as
    # the disconnect it was.
    test "a parked update request is answered rather than left to time out" do
      task = Task.async(fn -> NervesHubLink.check_for_update(Socket) end)

      assert_push(@device_topic, "check_update", %{})

      server_close()

      assert Task.await(task, 2_000) == {:error, :disconnected}
    end
  end

  describe "disconnecting from the server" do
    test "a close from NervesHub tells the client and raises the alarm", %{socket: socket} do
      server_close()

      assert_receive {:handle_error, :closed_by_remote}
      assert alarm_eventually_set?(NervesHubLink.Disconnected)
      assert Process.alive?(socket)
    end

    # An idle TCP connection can be dead for a long time without either end
    # noticing, and an unanswered heartbeat is how the device finds out. This
    # server is told to answer nothing, so the second heartbeat finds the first
    # outstanding.
    @tag socket_config: [heartbeat_interval_msec: 50]
    test "an unanswered heartbeat tells the client and raises the alarm", %{socket: socket} do
      assert_push("phoenix", "heartbeat", %{})

      assert_receive {:handle_error, :heartbeat_timeout}, 2_000
      assert alarm_eventually_set?(NervesHubLink.Disconnected)
      assert Process.alive?(socket)
    end
  end

  # Frames are handled in the order they arrive, so a message whose effect can
  # be seen marks everything sent before it as handled. Needed where a test
  # asserts that a message changed nothing, which cannot be waited for.
  defp assert_handled_in_order() do
    server_push(@device_topic, "identify", %{})

    assert_receive :identified, 2_000
  end

  # A topic has to be joined before the client will push to it.
  defp join_device_topic(%{socket: socket}) do
    assert_join(@device_topic, _params, :ok)
    await_joined(socket, :device)
    :ok
  end

  defp join_console_topic(%{socket: socket}) do
    assert_join(@console_topic, _params, :ok)
    await_joined(socket, :console)
    :ok
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
          params: %{"device_api_version" => "2.4.0"},
          rejoin_after: [1_000],
          remote_iex: false,
          remote_iex_timeout: 300,
          socket: [
            url: URI.parse("ws://localhost:#{start_server()}/socket/websocket"),
            reconnect_after_msec: [1_000]
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
