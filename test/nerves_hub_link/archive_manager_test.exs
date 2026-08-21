# SPDX-FileCopyrightText: 2026 Josh Kalderimis
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule NervesHubLink.ArchiveManagerTest do
  use ExUnit.Case, async: false

  import Mox

  alias NervesHubLink.ArchiveManager
  alias NervesHubLink.ClientMock
  alias NervesHubLink.Message.ArchiveInfo

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

    {:ok, manager: manager, archive_info: archive_info()}
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
end
