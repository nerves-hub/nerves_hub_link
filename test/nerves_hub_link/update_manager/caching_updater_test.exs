# SPDX-FileCopyrightText: 2026 Josh Kalderimis
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule NervesHubLink.UpdateManager.CachingUpdaterTest do
  use ExUnit.Case, async: true

  alias NervesHubLink.ClientMock
  alias NervesHubLink.FwupConfig
  alias NervesHubLink.Message.{FirmwareMetadata, UpdateInfo}
  alias NervesHubLink.Support.{FWUPStreamPlug, HTTPErrorPlug, Utils}
  alias NervesHubLink.UpdateManager.CachingUpdater

  setup do
    unique = System.unique_integer([:positive])
    cache_dir = Path.join(System.tmp_dir!(), "nerves_hub_link_cache_#{unique}")
    devpath = Path.join(System.tmp_dir!(), "nerves_hub_link_devpath_#{unique}")

    # This is the config key documented in `CachingUpdater`'s @moduledoc, and the
    # only one a user is told about. `cache_dir` used to be read from the bare
    # `CachingUpdater` atom (ie. `Elixir.CachingUpdater`), so this was silently
    # ignored and the default `/data/nerves_hub_link/firmware` was always used.
    Application.put_env(:nerves_hub_link, CachingUpdater, cache_dir: cache_dir)

    on_exit(fn ->
      Application.delete_env(:nerves_hub_link, CachingUpdater)
      _ = File.rm_rf(cache_dir)
      _ = File.rm(devpath)
    end)

    {:ok, _plug, port} = Utils.supervise_plug(FWUPStreamPlug)

    update_info = %UpdateInfo{
      firmware_url: URI.parse("http://localhost:#{port}/test.fw"),
      firmware_meta: %FirmwareMetadata{}
    }

    {:ok, cache_dir: cache_dir, devpath: devpath, update_info: update_info}
  end

  test "the partial download is created in the configured cache_dir", ctx do
    Process.flag(:trap_exit, true)

    test_pid = self()

    # the `Downloader` requires `:ok` back from its handler to keep going
    handler_fun = fn message ->
      send(test_pid, message)
      :ok
    end

    state = %{
      update_info: ctx.update_info,
      reporting_download_fun: handler_fun,
      last_progress_message: nil
    }

    {:ok, state} = CachingUpdater.start(state)

    assert state.cached_download_path == Path.join(ctx.cache_dir, "test.fw.partial")
    assert File.exists?(state.cached_download_path)

    assert_receive :complete, 5_000

    :ok = File.close(state.cached_download_pid)
  end

  test "the firmware is downloaded into the configured cache_dir and applied", ctx do
    Process.flag(:trap_exit, true)

    Mox.stub_with(ClientMock, NervesHubLink.ClientStub)

    fwup_config = %FwupConfig{fwup_devpath: ctx.devpath, fwup_task: "upgrade"}

    {:ok, updater} = CachingUpdater.start_link(ctx.update_info, fwup_config, [])

    Mox.allow(ClientMock, self(), updater)

    assert_receive {:EXIT, ^updater, {:shutdown, :update_complete}}, 10_000

    # the partial is renamed once the download completes, and the firmware is
    # left in the cache so a later attempt doesn't have to download it again
    assert File.exists?(Path.join(ctx.cache_dir, "test.fw"))
    refute File.exists?(Path.join(ctx.cache_dir, "test.fw.partial"))

    # `FWUPStreamPlug` serves firmware whose `upgrade` task writes this payload
    assert File.read!(ctx.devpath) =~ "Hello, world!"
  end

  # `NervesHubLink.Downloader` reports HTTP status errors as
  # `{:error, %Mint.HTTPError{reason: {:http_error, status}}}`. `CachingUpdater`
  # used to match on a bare `{:error, {:http_error, 404}}` tuple, so the clause
  # never ran and a stale partial could leave a device unable to ever update.
  for status <- [404, 416] do
    test "the cache directory is cleared when a resumed download is rejected with a #{status}",
         ctx do
      status = unquote(status)

      Process.flag(:trap_exit, true)

      {:ok, _plug, port} = Utils.supervise_plug(HTTPErrorPlug, status: status)

      update_info = %UpdateInfo{
        firmware_url: URI.parse("http://localhost:#{port}/test.fw"),
        firmware_meta: %FirmwareMetadata{}
      }

      # a stale partial from an earlier attempt. `start/1` keeps this file (it
      # only clears the *other* files in the cache) and resumes from it, which
      # is what gets the range request rejected.
      partial = Path.join(ctx.cache_dir, "test.fw.partial")
      :ok = File.mkdir_p(ctx.cache_dir)
      :ok = File.write(partial, "stale partial contents")

      fwup_config = %FwupConfig{fwup_devpath: ctx.devpath, fwup_task: "upgrade"}

      {:ok, updater} = CachingUpdater.start_link(update_info, fwup_config, [])

      assert_receive {:EXIT, ^updater, {:shutdown, {:download_error, {:http_error, ^status}}}},
                     5_000

      refute File.exists?(partial)
      assert File.ls!(ctx.cache_dir) == []
    end
  end
end
