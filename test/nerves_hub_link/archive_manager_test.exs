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

      assert ArchiveManager.apply_archive(context.manager, info, keys) == :downloading
      assert_received {:archive_available, _uuid}
      assert_receive {:gated_request, :first, request}, @timeout

      # The repeat offer is dropped before the client is asked about it. The
      # client is asked inside the call, so by the time it has returned a second
      # download either started or never will.
      assert ArchiveManager.apply_archive(context.manager, info, keys) == :downloading

      refute_received {:archive_available, _uuid},
                      "the client was asked about the repeat offer"

      send(request, :release)

      assert_receive {:archive_ready, ready_uuid, ready_contents}, @timeout
      assert ready_uuid == info.uuid
      assert ready_contents == contents, "the archive handed to the client was corrupted"
      refute_received {:archive_ready, _uuid, _contents}, "the client was told twice"

      refute_receive {:DOWN, ^ref, :process, _pid, _reason}, 1_000, "ArchiveManager crashed"

      assert ArchiveManager.status(context.manager) == :idle
    end

    test "a different archive offered mid-download is held until the first finishes",
         context do
      %{first: first, second: second} = context.archives
      keys = [context.public_key]
      ref = Process.monitor(context.manager)

      assert ArchiveManager.apply_archive(context.manager, first.info, keys) == :downloading
      assert_received {:archive_available, first_offered}
      assert first_offered == first.info.uuid
      assert_receive {:gated_request, :first, first_request}, @timeout

      # Offer the other archive. The client isn't asked about it yet, which is
      # what stops a second download writing over the first.
      assert ArchiveManager.apply_archive(context.manager, second.info, keys) == :downloading

      refute_received {:archive_available, _uuid},
                      "a second download started while one was in progress"

      send(first_request, :release)

      # The first archive arrives intact ...
      assert_receive {:archive_ready, first_uuid, first_contents}, @timeout
      assert first_uuid == first.info.uuid
      assert first_contents == first.contents, "the first archive was corrupted"

      # ... and the held archive is offered once it has
      assert_receive {:gated_request, :second, second_request}, @timeout
      send(second_request, :release)

      assert_receive {:archive_ready, second_uuid, second_contents}, @timeout
      assert second_uuid == second.info.uuid
      assert second_contents == second.contents, "the held archive was corrupted"

      refute_receive {:DOWN, ^ref, :process, _pid, _reason}, 1_000, "ArchiveManager crashed"

      assert ArchiveManager.status(context.manager) == :idle

      assert Path.wildcard(Path.join(context.data_path, "archives/*.download")) == [],
             "a partial download was left behind"
    end

    test "a repeat of the downloading archive drops an archive held behind it", context do
      %{first: first, second: second} = context.archives
      keys = [context.public_key]

      assert ArchiveManager.apply_archive(context.manager, first.info, keys) == :downloading
      assert_received {:archive_available, _uuid}
      assert_receive {:gated_request, :first, first_request}, @timeout

      # The second archive is held behind the download in progress ...
      assert ArchiveManager.apply_archive(context.manager, second.info, keys) == :downloading

      # ... and then NervesHub offers the downloading archive again
      assert ArchiveManager.apply_archive(context.manager, first.info, keys) == :downloading
      refute_received {:archive_available, _uuid}

      send(first_request, :release)

      assert_receive {:archive_ready, ready_uuid, _contents}, @timeout
      assert ready_uuid == first.info.uuid

      # This call is answered after the manager has finished with the completed
      # download, so anything held would already have been offered.
      assert ArchiveManager.status(context.manager) == :idle

      refute_received {:archive_available, _uuid},
                      "the held archive was offered after the repeat offer"

      refute_received {:archive_ready, _uuid, _contents}
    end

    test "an archive held while the download before it fails is still offered", context do
      %{first: first, second: second} = context.archives
      keys = [context.public_key]
      ref = Process.monitor(context.manager)

      assert ArchiveManager.apply_archive(context.manager, first.info, keys) == :downloading
      assert_received {:archive_available, _uuid}
      assert_receive {:gated_request, :first, first_request}, @timeout

      assert ArchiveManager.apply_archive(context.manager, second.info, keys) == :downloading
      refute_received {:archive_available, _uuid}

      # Fail the download in progress rather than finish it
      send(first_request, :fail)

      assert_receive {:gated_request, :second, second_request}, @timeout
      send(second_request, :release)

      assert_receive {:archive_ready, uuid, archive_contents}, @timeout
      assert uuid == second.info.uuid
      assert archive_contents == second.contents, "the held archive was corrupted"

      refute_receive {:DOWN, ^ref, :process, _pid, _reason}, 1_000, "ArchiveManager crashed"

      assert ArchiveManager.status(context.manager) == :idle

      assert Path.wildcard(Path.join(context.data_path, "archives/*.download")) == [],
             "the failed download was left behind"
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
