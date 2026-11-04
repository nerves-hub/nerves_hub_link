# SPDX-FileCopyrightText: 2026 Jon Carstens
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule NervesHubLink.UpdateManager.UpdaterProgressTest do
  use ExUnit.Case, async: false

  alias NervesHubLink.ClientMock
  alias NervesHubLink.FwupConfig
  alias NervesHubLink.Message.{FirmwareMetadata, UpdateInfo}
  alias NervesHubLink.Support.{FWUPStreamPlug, Utils}
  alias NervesHubLink.UpdateManager.CachingUpdater

  # An updater that hands its work to another one and reports the download as the
  # second half of the bar, as one that does work of its own first would.
  defmodule Delegating do
    use NervesHubLink.UpdateManager.Updater

    @impl NervesHubLink.UpdateManager.Updater
    defdelegate start(state), to: CachingUpdater

    @impl NervesHubLink.UpdateManager.Updater
    defdelegate handle_downloader_message(message, state), to: CachingUpdater

    @impl NervesHubLink.UpdateManager.Updater
    def handle_progress(:downloading, percent, state) do
      send(:updater_progress_test, {:downloading, percent})
      super(:downloading, 50 + percent / 2, state)
    end

    def handle_progress(stage, percent, state) do
      send(:updater_progress_test, {stage, percent})
      super(stage, percent, state)
    end
  end

  setup do
    cache_dir =
      Path.join(
        System.tmp_dir!(),
        "nerves_hub_link_progress_#{System.unique_integer([:positive])}"
      )

    devpath = cache_dir <> ".img"
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

    {:ok, devpath: devpath, update_info: update_info}
  end

  test "an updater that delegates still reports the progress itself", ctx do
    Process.flag(:trap_exit, true)
    Process.register(self(), :updater_progress_test)
    Mox.stub_with(ClientMock, NervesHubLink.ClientStub)

    fwup_config = %FwupConfig{fwup_devpath: ctx.devpath, fwup_task: "upgrade"}
    {:ok, updater} = Delegating.start_link(ctx.update_info, fwup_config, [])
    Mox.allow(ClientMock, self(), updater)

    assert_receive {:downloading, _percent}, 10_000
    assert_receive {:updating, _percent}, 10_000
    assert_receive {:EXIT, ^updater, {:shutdown, :update_complete}}, 10_000
  end
end
