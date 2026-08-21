# SPDX-FileCopyrightText: 2026 Josh Kalderimis
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule NervesHubLink.UpdateManager.PartsUpdaterTest do
  @moduledoc """
  End to end tests for the parts based update strategy.

  These run real downloads over HTTP against a server that honours range
  requests, and hand the result to a real `fwup`, because what is being tested
  is exactly the seam between those two: which bytes get asked for after an
  interruption, and what happens when the bytes that come back aren't the ones
  the update payload described.
  """

  use ExUnit.Case, async: false

  import Mox

  alias Fwup.TestSupport.Fixtures
  alias NervesHubLink.ClientMock
  alias NervesHubLink.ClientStub
  alias NervesHubLink.FwupConfig
  alias NervesHubLink.Message.FirmwareMetadata
  alias NervesHubLink.Message.UpdateInfo
  alias NervesHubLink.Support.RangedFilePlug
  alias NervesHubLink.Support.SocketStub
  alias NervesHubLink.Support.Utils
  alias NervesHubLink.UpdateManager
  alias NervesHubLink.UpdateManager.PartsUpdater

  # Downloading and applying a 1KB firmware is quick, but starting fwup and
  # running the port isn't instant. Be generous so this isn't flaky on CI.
  @timeout 10_000

  # The test firmware is a few hundred bytes, so a small part size is what gives
  # these tests a firmware made of several parts to lose and re-fetch.
  @part_size 100

  @uuid "8a8b902c-d1a9-58aa-6111-04ab57c2f2a8"

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
    key_name = "parts-updater-#{unique}"
    :ok = Fixtures.gen_key_pair(key_name)

    {:ok, firmware_path} =
      Fixtures.create_signed_firmware(key_name, "unsigned-#{unique}", "signed-#{unique}")

    cache_dir = Path.join(System.tmp_dir!(), "nerves_hub_link_parts_#{unique}")
    devpath = Path.join(System.tmp_dir!(), "fwup_output_#{unique}")

    configure(cache_dir: cache_dir, part_size: @part_size)

    on_exit(fn ->
      Application.delete_env(:nerves_hub_link, PartsUpdater)
      _ = File.rm_rf(cache_dir)
      _ = File.rm(devpath)
    end)

    {:ok,
     cache_dir: cache_dir,
     devpath: devpath,
     firmware: File.read!(firmware_path),
     firmware_path: firmware_path,
     public_key: Fixtures.get_public_key(key_name)}
  end

  describe "downloading" do
    test "downloads the firmware in parts, verifies each one, and applies it", context do
      counter = :counters.new(2, [])
      update_info = serve(context, counter: counter)

      apply_update(context, update_info)

      assert_receive {:fwup, {:ok, 0, _message}}, @timeout
      assert_receive {:update_status, :completed}, @timeout

      assert File.read!(context.devpath) =~ "Hello, world!"

      # every part is kept, so a later attempt at the same firmware doesn't have
      # to download it again
      assert parts_on_disk(context) == expected_parts(context)

      # splitting the firmware into parts doesn't split the download into one
      # request per part - by default the whole thing still arrives over a
      # single connection
      assert :counters.get(counter, 1) == 1
    end

    test "reports progress while downloading and applying", context do
      update_info = serve(context)

      apply_update(context, update_info)

      assert_receive {:update_status, {:started, _network_interface}}, @timeout
      assert_receive {:update_status, {:downloading, 100}}, @timeout
      assert_receive {:update_status, :completed}, @timeout
    end

    test "downloads as a single part when the configured part size can't be right", context do
      # a `part_size` that would split this firmware into a different number of
      # parts than the payload has checksums for makes the checksums unusable,
      # which shouldn't be allowed to stop the update
      configure(part_size: @part_size * 3)

      update_info = serve(context)

      apply_update(context, update_info)

      assert_receive {:update_status, :completed}, @timeout
      assert File.read!(context.devpath) =~ "Hello, world!"

      assert parts_on_disk(context) == [context.firmware]
    end

    test "downloads as a single part when the payload has no part checksums", context do
      update_info = %{serve(context) | partials_checksums: []}

      apply_update(context, update_info)

      assert_receive {:update_status, :completed}, @timeout
      assert File.read!(context.devpath) =~ "Hello, world!"

      assert parts_on_disk(context) == [context.firmware]
    end
  end

  describe "resuming" do
    test "picks up after the parts that are already downloaded and verified", context do
      update_info = serve(context)

      write_parts(context, 0..2)

      apply_update(context, update_info)

      assert_receive {:range_request, first, _last}, @timeout
      assert first == 3 * @part_size

      assert_receive {:update_status, :completed}, @timeout
      assert parts_on_disk(context) == expected_parts(context)
    end

    test "keeps the bytes of a part that was still being written", context do
      update_info = serve(context)

      write_parts(context, 0..0)
      write_part(context, 1, binary_part(Enum.at(expected_parts(context), 1), 0, 40))

      apply_update(context, update_info)

      assert_receive {:range_request, first, _last}, @timeout
      assert first == @part_size + 40

      assert_receive {:update_status, :completed}, @timeout
      assert parts_on_disk(context) == expected_parts(context)
    end

    test "downloads a cached part again when it doesn't match its checksum", context do
      update_info = serve(context)

      write_parts(context, 0..2)
      # right size, wrong bytes, which is what a part written during a power cut
      # can look like
      write_part(context, 1, :binary.copy(<<0>>, @part_size))

      apply_update(context, update_info)

      assert_receive {:range_request, first, _last}, @timeout
      assert first == @part_size

      assert_receive {:update_status, :completed}, @timeout
      assert parts_on_disk(context) == expected_parts(context)
    end

    test "starts a part fresh when the download reaches it from the part before", context do
      counter = :counters.new(2, [])
      update_info = serve(context, counter: counter)

      # part 2 has bytes from an earlier attempt, but the download will reach it
      # by streaming through part 1, so those bytes are of no use and appending
      # to them would corrupt the part
      write_parts(context, [0])
      write_part(context, 2, binary_part(Enum.at(expected_parts(context), 2), 0, 40))

      apply_update(context, update_info)

      assert_receive {:update_status, :completed}, @timeout
      assert parts_on_disk(context) == expected_parts(context)

      # one request, so no part had to be downloaded a second time
      assert :counters.get(counter, 1) == 1
      assert requested_ranges() == [{@part_size, last_byte(context)}]
    end

    test "skips the download entirely when every part is already on disk", context do
      update_info = serve(context)

      write_parts(context, 0..(part_count(context) - 1))

      apply_update(context, update_info)

      assert_receive {:update_status, :completed}, @timeout
      assert File.read!(context.devpath) =~ "Hello, world!"

      refute_received {:range_request, _first, _last}
    end
  end

  describe "downloading several parts at once" do
    test "splits the parts across the configured number of connections", context do
      configure(max_concurrent_parts: 4)

      counter = :counters.new(2, [])
      update_info = serve(context, counter: counter)

      apply_update(context, update_info)

      assert_receive {:update_status, :completed}, @timeout
      assert File.read!(context.devpath) =~ "Hello, world!"

      # 8 parts over 4 connections is two parts each, and the last range runs to
      # the end of the file rather than to a part boundary
      assert part_count(context) == 8
      assert :counters.get(counter, 1) == 4

      assert requested_ranges() == [
               {0, 199},
               {200, 399},
               {400, 599},
               {600, last_byte(context)}
             ]

      assert parts_on_disk(context) == expected_parts(context)
    end

    test "only asks for the parts that are missing", context do
      configure(max_concurrent_parts: 4)

      counter = :counters.new(2, [])
      update_info = serve(context, counter: counter)

      # a gap in the middle, which is what a run of parallel downloads leaves
      # behind when it is interrupted
      write_parts(context, [0, 1, 4, 5])

      apply_update(context, update_info)

      assert_receive {:update_status, :completed}, @timeout

      # four parts left to fetch and four connections to fetch them with, none of
      # which asks for anything that was already verified
      assert part_count(context) == 8
      assert :counters.get(counter, 1) == 4

      assert requested_ranges() == [
               {200, 299},
               {300, 399},
               {600, 699},
               {700, last_byte(context)}
             ]

      assert parts_on_disk(context) == expected_parts(context)
    end

    test "a part failing in one range doesn't disturb the others", context do
      configure(max_concurrent_parts: 4)

      update_info =
        serve(context,
          counter: :counters.new(2, []),
          corrupt: {4 * @part_size, @part_size},
          corrupt_requests: 1
        )

      apply_update(context, update_info)

      assert_receive {:update_status, :completed}, @timeout
      assert File.read!(context.devpath) =~ "Hello, world!"

      assert parts_on_disk(context) == expected_parts(context)
    end
  end

  describe "when a part arrives corrupted" do
    test "downloads that part again and finishes the update", context do
      counter = :counters.new(2, [])

      update_info =
        serve(context,
          counter: counter,
          corrupt: {2 * @part_size, @part_size},
          corrupt_requests: 1
        )

      apply_update(context, update_info)

      assert_receive {:update_status, :completed}, @timeout
      assert File.read!(context.devpath) =~ "Hello, world!"

      # the whole file, then the part that failed and everything after it
      assert :counters.get(counter, 1) == 2
      assert_receive {:range_request, 0, _last}, @timeout
      assert_receive {:range_request, first, _last}, @timeout
      assert first == 2 * @part_size

      assert parts_on_disk(context) == expected_parts(context)
    end

    test "fails the update once the part has run out of attempts", context do
      configure(max_part_attempts: 2)

      counter = :counters.new(2, [])

      update_info = serve(context, counter: counter, corrupt: {2 * @part_size, @part_size})

      apply_update(context, update_info)

      assert_receive {:update_status, {:failed, message}}, @timeout
      assert message =~ "part_verification_failed"

      assert :counters.get(counter, 1) == 2

      # the parts before the one that kept failing are still there for the next
      # attempt to pick up
      assert parts_on_disk(context) == Enum.take(expected_parts(context), 2)
    end
  end

  ##
  # Helpers
  #

  defp apply_update(context, update_info) do
    manager =
      start_supervised!(%{
        id: UpdateManager,
        start:
          {UpdateManager, :start_link,
           [{%FwupConfig{fwup_devpath: context.devpath, fwup_task: "upgrade"}, PartsUpdater}]}
      })

    assert UpdateManager.apply_update(manager, update_info, [context.public_key]) == :updating

    manager
  end

  defp serve(context, opts \\ []) do
    opts = Keyword.merge([path: context.firmware_path, test_pid: self()], opts)

    {:ok, _server, port} = Utils.supervise_plug(RangedFilePlug, opts)

    %UpdateInfo{
      firmware_url: URI.parse("http://localhost:#{port}/firmware.fw"),
      firmware_meta: %FirmwareMetadata{uuid: @uuid},
      size: byte_size(context.firmware),
      checksum: Base.encode16(:crypto.hash(:sha256, context.firmware)),
      partials_checksums:
        Enum.map(expected_parts(context), &Base.encode16(:crypto.hash(:sha256, &1)))
    }
  end

  defp configure(opts) do
    settings = Application.get_env(:nerves_hub_link, PartsUpdater, [])
    Application.put_env(:nerves_hub_link, PartsUpdater, Keyword.merge(settings, opts))
  end

  defp expected_parts(context), do: split(context.firmware, @part_size)

  # The size of a signed firmware depends on the version of fwup that built it,
  # so the end of the file is worked out from the firmware the test is actually
  # serving rather than written down.
  defp last_byte(context), do: byte_size(context.firmware) - 1

  defp part_count(context), do: length(expected_parts(context))

  defp split(<<>>, _size), do: []
  defp split(binary, size) when byte_size(binary) <= size, do: [binary]

  defp split(binary, size) do
    <<head::binary-size(size), rest::binary>> = binary
    [head | split(rest, size)]
  end

  defp write_parts(context, indexes) do
    parts = expected_parts(context)

    Enum.each(indexes, fn index -> write_part(context, index, Enum.at(parts, index)) end)
  end

  defp write_part(context, index, contents) do
    path = part_path(context, index)
    :ok = File.mkdir_p(Path.dirname(path))
    :ok = File.write(path, contents)
  end

  defp part_path(context, index) do
    Path.join([
      context.cache_dir,
      @uuid,
      "part-" <> String.pad_leading(Integer.to_string(index), 5, "0")
    ])
  end

  defp requested_ranges() do
    receive do
      {:range_request, first, last} -> [{first, last} | requested_ranges()]
    after
      0 -> []
    end
    |> Enum.sort()
  end

  defp parts_on_disk(context) do
    case File.ls(Path.join(context.cache_dir, @uuid)) do
      {:ok, entries} ->
        entries
        |> Enum.sort()
        |> Enum.map(&File.read!(Path.join([context.cache_dir, @uuid, &1])))

      {:error, _reason} ->
        []
    end
  end
end
