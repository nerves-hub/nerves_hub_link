defmodule NervesHubLink.UpdateManager.StreamingUpdater do
  use NervesHubLink.UpdateManager.Updater

  alias NervesHubLink.Downloader
  alias NervesHubLink.FwupConfig
  alias NervesHubLink.UpdateInfo

  require Logger

  @impl NervesHubLink.UpdateManager.Updater
  def start(state) do
    {:ok, download} =
      Downloader.start_download(state.update_info.firmware_url, state.reporting_download_fun)

    {:ok, fwup} =
      Fwup.stream(self(), fwup_args(state.fwup_config, state.fwup_public_keys),
        fwup_env: state.fwup_config.fwup_env
      )

    url_without_query =
      state.update_info.firmware_url
      |> URI.to_string()
      |> String.replace(~r/\?.*/, "?...")

    Logger.info("[#{log_prefix()}] Downloading firmware: #{url_without_query}")

    {:ok,
     Map.merge(state, %{
       status: {:updating, 0},
       download: download,
       fwup: fwup
     })}
  end

  @impl NervesHubLink.UpdateManager.Updater
  def handle_downloader_message(:complete, state) do
    Logger.info("[#{log_prefix()}] Firmware download complete")
    {:ok, state}
  end

  def handle_downloader_message({:error, reason}, state) do
    Logger.error("[#{log_prefix()}] Nonfatal HTTP download error: #{inspect(reason)}")
    {:ok, state}
  end

  # Data from the downloader is sent to fwup
  def handle_downloader_message({:data, data, _percent}, state) do
    _ = Fwup.Stream.send_chunk(state.fwup, data)
    {:ok, state}
  end

  @spec fwup_args(FwupConfig.t(), list(String.t())) :: [String.t()]
  defp fwup_args(%FwupConfig{} = config, fwup_public_keys) do
    args = ["--apply", "--no-unmount", "-d", config.fwup_devpath, "--task", config.fwup_task]

    Enum.reduce(fwup_public_keys, args, fn public_key, args ->
      args ++ ["--public-key", public_key]
    end)
  end

  def log_prefix(), do: "NervesHubLink:StreamingUpdater"
end
