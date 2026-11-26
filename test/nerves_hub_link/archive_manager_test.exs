# SPDX-FileCopyrightText: 2026 Josh Kalderimis
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule NervesHubLink.ArchiveManagerTest do
  use ExUnit.Case, async: false

  import Mox

  alias Fwup.TestSupport.Fixtures
  alias NervesHubLink.ArchiveManager
  alias NervesHubLink.ClientMock
  alias NervesHubLink.Message.ArchiveInfo
  alias NervesHubLink.Support.FirmwareFilePlug
  alias NervesHubLink.Support.GatedFilePlug
  alias NervesHubLink.Support.HTTPErrorPlug
  alias NervesHubLink.Support.SocketStub
  alias NervesHubLink.Support.Utils

  # Downloading a 1KB archive is quick, but `fwup -V` runs before the client
  # hears it's ready. Be generous so this isn't flaky on CI.
  @timeout 10_000

  setup :set_mox_global
  setup :verify_on_exit!

  setup do
    stub_with(ClientMock, NervesHubLink.ClientStub)

    data_path = Path.join(System.tmp_dir!(), "archive_manager_test_#{System.unique_integer()}")
    File.mkdir_p!(data_path)
    on_exit(fn -> File.rm_rf(data_path) end)

    manager =
      start_supervised!(%{
        id: ArchiveManager,
        start: {ArchiveManager, :start_link, [%{data_path: data_path}]}
      })

    {:ok, manager: manager, archive_info: archive_info(), data_path: data_path}
  end

  describe "refusing archives that cannot be verified" do
    test "an archive is refused when no public keys are available", context do
      # `fwup -V` exits 0 when given no public key, so an unsigned archive would
      # otherwise validate successfully. Answering `:download` here makes the
      # manager report `:downloading` unless the archive is refused first.
      stub(ClientMock, :archive_available, fn _ -> :download end)

      assert ArchiveManager.apply_archive(context.manager, context.archive_info, []) == :idle
      assert ArchiveManager.currently_downloading_uuid(context.manager) == nil
    end

    test "a refused archive is never offered to the client", context do
      expect(ClientMock, :archive_available, 0, fn _ -> :download end)

      assert ArchiveManager.apply_archive(context.manager, context.archive_info, []) == :idle
    end

    test "keys that are not binaries do not count as public keys", context do
      expect(ClientMock, :archive_available, 0, fn _ -> :download end)

      assert ArchiveManager.apply_archive(context.manager, context.archive_info, [nil, :key]) ==
               :idle
    end

    test "a refused archive leaves the manager usable", context do
      expect(ClientMock, :archive_available, fn _ -> :ignore end)

      assert ArchiveManager.apply_archive(context.manager, context.archive_info, []) == :idle

      assert ArchiveManager.apply_archive(context.manager, context.archive_info, ["a key"]) ==
               :idle

      assert ArchiveManager.currently_downloading_uuid(context.manager) == nil
    end
  end

  describe "downloading an archive" do
    setup do
      test_pid = self()

      _ = start_supervised!({SocketStub, test_pid})

      unique = System.unique_integer([:positive])
      key_name = "archive-manager-#{unique}"
      :ok = Fixtures.gen_key_pair(key_name)

      {:ok, path} =
        Fixtures.create_signed_firmware(
          key_name,
          "unsigned-archive-#{unique}",
          "signed-archive-#{unique}"
        )

      {:ok, _server, port} = Utils.supervise_plug(FirmwareFilePlug, path: path)

      stub(ClientMock, :archive_available, fn _ -> :download end)

      stub(ClientMock, :archive_ready, fn _info, file_path ->
        send(test_pid, {:archive_ready, file_path})
        :ok
      end)

      {:ok,
       archive_info: %{archive_info() | url: "http://localhost:#{port}/#{Path.basename(path)}"},
       public_key: Fixtures.get_public_key(key_name)}
    end

    test "doesn't tell NervesHub a firmware update has started", context do
      # NervesHub takes a download that reports it has started for a firmware
      # update, and refuses the device's next real one while it waits for this
      # one to finish.
      assert ArchiveManager.apply_archive(context.manager, context.archive_info, [
               context.public_key
             ]) == :downloading

      assert_receive {:archive_ready, _file_path}, @timeout

      # Anything the download sent the socket has reached this process once the
      # socket has answered a call made after it.
      _ = :sys.get_state(NervesHubLink.Socket)
      refute_received {:update_status, _status}
    end
  end

  describe "archives offered while one is downloading" do
    # NervesHub sometimes sends the same "archive" message twice, tens of
    # milliseconds apart, when a deployment changes shortly after a device
    # joins.

    setup :prepare_archives_downloads

    test "the same archive offered twice is downloaded once, intact", context do
      %{info: info, contents: contents} = context.archives.first
      keys = [context.public_key]
      ref = Process.monitor(context.manager)

      # Verify the download has been started
      assert ArchiveManager.apply_archive(context.manager, info, keys) == :downloading
      assert_receive {:gated_request, :first, first_request}, @timeout

      # Start the second download
      _ = ArchiveManager.apply_archive(context.manager, info, keys)

      # Wait to see if a second download starts
      second_request =
        receive do
          {:gated_request, :first, pid} -> pid
        after
          500 -> nil
        end

      # Let the file contents through
      for pid <- [first_request, second_request], pid, do: send(pid, :release)

      # The client shouldn't crash
      refute_receive {:DOWN, ^ref, :process, _pid, _reason}, 1_000, "ArchiveManager crashed"

      # The contents should be not be mangled
      assert_receive {:archive_ready, uuid, ready_contents}, @timeout
      assert uuid == info.uuid
      assert ready_contents == contents, "the archive handed to the client was corrupted"

      # And only delivered once
      refute_received {:archive_ready, _uuid, _contents}
      assert Process.alive?(context.manager)

      # The archive should be available once
      assert_received {:archive_available, _uuid}
      refute_received {:archive_available, _uuid}, "the client was asked about the repeat offer"

      assert ArchiveManager.status(context.manager) == :idle
    end

    test "a different archive offered mid-download doesn't corrupt or crash", context do
      %{first: first, second: second} = context.archives
      keys = [context.public_key]
      ref = Process.monitor(context.manager)

      # Verify the first archive is downloading
      assert ArchiveManager.apply_archive(context.manager, first.info, keys) == :downloading
      assert_receive {:gated_request, :first, first_request}, @timeout

      # Start the other archive
      _ = ArchiveManager.apply_archive(context.manager, second.info, keys)

      second_request =
        receive do
          {:gated_request, :second, pid} -> pid
        after
          500 -> nil
        end

      for pid <- [first_request, second_request], pid, do: send(pid, :release)

      # The client shouldn't crash
      refute_receive {:DOWN, ^ref, :process, _pid, _reason}, 1_000, "ArchiveManager crashed"

      # Whichever archive the manager settles on, it must be the bytes of that
      # archive, and the client hears about it once.
      assert_receive {:archive_ready, uuid, ready_contents}, @timeout

      expected =
        Enum.find_value([first, second], fn %{info: info, contents: c} ->
          if info.uuid == uuid, do: c
        end)

      # the contents should be unmangled
      assert ready_contents == expected,
             "the archive handed to the client doesn't match the archive it was told about"

      # The archive should be ready
      refute_received {:archive_ready, _uuid, _contents}
      assert Process.alive?(context.manager)

      # The 2nd archive should not have downloaded any bits
      assert Path.wildcard(Path.join(context.data_path, "archives/*.download")) == [],
             "a partial download was left behind"
    end
  end

  describe "a download that fails" do
    test "doesn't take the manager down with it", context do
      {:ok, _server, port} = Utils.supervise_plug(HTTPErrorPlug, status: 500)
      info = %{context.archive_info | url: "http://localhost:#{port}/test.fw"}
      stub(ClientMock, :archive_available, fn _ -> :download end)
      ref = Process.monitor(context.manager)

      assert ArchiveManager.apply_archive(context.manager, info, ["a key"]) == :downloading

      refute_receive {:DOWN, ^ref, :process, _pid, _reason}, 2_000, "ArchiveManager crashed"
      assert ArchiveManager.status(context.manager) == :idle
    end
  end

  defp archive_info() do
    %ArchiveInfo{
      architecture: "arm",
      description: "test archive",
      platform: "rpi0",
      size: 1024,
      url: "http://localhost/test.fw",
      uuid: "6f1f9d4a-1b3e-4c9a-9a1e-3c9d5f2b7a10",
      version: "1.0.0"
    }
  end

  defp prepare_archives_downloads(_) do
    test_pid = self()

    _ = start_supervised!({SocketStub, test_pid})

    unique = System.unique_integer([:positive])
    key_name = "archive-manager-overlap-#{unique}"
    :ok = Fixtures.gen_key_pair(key_name)

    archives =
      for tag <- [:first, :second], into: %{} do
        {:ok, path} =
          Fixtures.create_signed_firmware(
            key_name,
            "unsigned-#{tag}-archive-#{unique}",
            "signed-#{tag}-archive-#{unique}",
            %{description: "#{tag} archive"}
          )

        {:ok, _server, port} =
          Utils.supervise_plug(GatedFilePlug, path: path, test_pid: test_pid, tag: tag)

        info = %{
          archive_info()
          | url: "http://localhost:#{port}/#{Path.basename(path)}",
            uuid: Ecto.UUID.generate()
        }

        {tag, %{info: info, contents: File.read!(path)}}
      end

    stub(ClientMock, :archive_available, fn info ->
      send(test_pid, {:archive_available, info.uuid})
      :download
    end)

    stub(ClientMock, :archive_ready, fn info, file_path ->
      # Read it now: the manager may replace the file once this returns.
      send(test_pid, {:archive_ready, info.uuid, File.read!(file_path)})
      :ok
    end)

    {:ok, archives: archives, public_key: Fixtures.get_public_key(key_name)}
  end
end
