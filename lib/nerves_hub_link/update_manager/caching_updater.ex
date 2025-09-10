# SPDX-FileCopyrightText: 2025 Josh Kalderimis
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule NervesHubLink.UpdateManager.CachingUpdater do
  @moduledoc false
  use NervesHubLink.UpdateManager.Updater

  alias NervesHubLink.Downloader
  alias NervesHubLink.FwupConfig
  alias NervesHubLink.UpdateInfo

  require Logger

  @impl NervesHubLink.UpdateManager.Updater
  def start(state) do
    firmware_url = URI.to_string(state.update_info.firmware_url)

    path_parts = String.split(firmware_url, "/")
    file_name_with_query = List.last(path_parts)
    file_name = String.replace(file_name_with_query, ~r/\?.*/, "")

    firmware_dir = settings()[:cache_dir]

    full_path = Path.join(firmware_dir, "#{file_name}.partial")

    clean_caching_directory(firmware_dir, "#{file_name}.partial")

    start_from =
      case File.stat(full_path) do
        {:ok, stat} ->
          Logger.info("[#{log_prefix()}] Partial firmware download exists (#{stat.size} bytes)")
          stat.size

        {:error, _} ->
          Logger.info("[#{log_prefix()}] No partial firmware download found")
          0
      end

    file_pid = File.open!(full_path, [:read, :append, :raw, :binary])

    {:ok, download} =
      Downloader.start_download(firmware_url, state.reporting_download_fun,
        resume_from_bytes: start_from
      )

    Logger.info(
      "[#{log_prefix()}] Downloading firmware: #{String.replace(firmware_url, ~r/\?.*/, "?...")}"
    )

    {:ok,
     Map.merge(
       state,
       %{
         status: {:downloading, 0},
         download: download,
         cached_download_pid: file_pid,
         cached_download_path: full_path
       }
     )}
  end

  @impl NervesHubLink.UpdateManager.Updater
  def handle_downloader_message(:complete, state) do
    :ok = File.close(state.cached_download_pid)

    firmware_file_path = String.trim_trailing(state.cached_download_path, ".partial")
    :ok = File.rename(state.cached_download_path, firmware_file_path)

    {:ok, stat} = File.stat(firmware_file_path)

    Logger.info("[NervesHubLink] Firmware download complete (#{stat.size} bytes)")
    Logger.info("[NervesHubLink] Requesting FWUP apply the firmware update")

    {:ok, fwup} =
      Fwup.stream(
        self(),
        fwup_args(state.fwup_config, firmware_file_path, state.fwup_public_keys),
        fwup_env: state.fwup_config.fwup_env
      )

    {:ok,
     Map.merge(state, %{
       cached_download_pid: nil,
       cached_download_path: firmware_file_path,
       fwup: fwup,
       status: {:updating, 0}
     })}
  end

  def handle_downloader_message({:error, reason}, state) do
    Logger.error("[#{log_prefix()}] Nonfatal HTTP download error: #{inspect(reason)}")
    {:ok, state}
  end

  # Data from the downloader is sent to fwup
  def handle_downloader_message({:data, data, percent}, state) do
    IO.binwrite(state.cached_download_pid, data)

    NervesHubLink.send_update_progress(round(percent))

    {:ok, state}
  rescue
    error ->
      Logger.error(
        "[#{log_prefix()}] Failed to write to cached download file: #{inspect(error)} - #{inspect(state)}"
      )

      {:error, error, state}
  end

  @impl NervesHubLink.UpdateManager.Updater
  def cleanup(%{cached_download_pid: cached_download_pid}) do
    case File.close(cached_download_pid) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error("[#{log_prefix()}] Failed to close cached download file: #{inspect(reason)}")
        :ok
    end
  end

  def cleanup(_state), do: :ok

  defp clean_caching_directory(caching_dir, file_name) do
    case File.ls(caching_dir) do
      {:ok, file_list} ->
        file_list = Enum.reject(file_list, fn name -> name == file_name end)

        if Enum.any?(file_list) do
          Logger.info(
            "[#{log_prefix()}] Removing #{Enum.count(file_list)} previous firmware files from the cache directory"
          )

          Enum.each(file_list, &File.rm(Path.join(caching_dir, &1)))
        end

        :ok

      _ ->
        :ok = File.mkdir_p(caching_dir)
    end
  end

  defp fwup_args(%FwupConfig{} = config, firmware_path, fwup_public_keys) do
    args = [
      "--apply",
      "--no-unmount",
      "-d",
      config.fwup_devpath,
      "--task",
      config.fwup_task,
      "-i",
      firmware_path
    ]

    Enum.reduce(fwup_public_keys, args, fn public_key, args ->
      args ++ ["--public-key", public_key]
    end)
  end

  @impl NervesHubLink.UpdateManager.Updater
  def log_prefix(), do: "NervesHubLink:CachingUpdater"

  defp settings() do
    Application.get_env(:nerves_hub_link, CachingUpdater,
      cache_dir: "/data/nerves_hub_link/firmware"
    )
  end
end
