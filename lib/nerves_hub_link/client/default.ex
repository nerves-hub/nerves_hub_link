defmodule NervesHubLink.Client.Default do
  @moduledoc """
  Default NervesHubLink.Client implementation

  This client always accepts an update.
  """

  @behaviour NervesHubLink.Client
  require Logger

  @impl NervesHubLink.Client
  def update_available(update_info) do
    if update_info.firmware_meta.uuid == Nerves.Runtime.KV.get_active("nerves_fw_uuid") do
      Logger.info("""
      [NervesHubLink.Client] Ignoring request to update to the same firmware

      #{inspect(update_info)}
      """)

      :ignore
    else
      :apply
    end
  end

  @impl NervesHubLink.Client
  def archive_available(archive_info) do
    Logger.info(
      "[NervesHubLink.Client] Archive is available for downloading #{inspect(archive_info)}"
    )

    :ignore
  end

  @impl NervesHubLink.Client
  def archive_ready(archive_info, file_path) do
    Logger.info(
      "[NervesHubLink.Client] Archive is ready for processing #{inspect(archive_info)} at #{inspect(file_path)}"
    )

    :ok
  end

  @impl NervesHubLink.Client
  def handle_fwup_message({:progress, percent}) do
    Logger.debug("[NervesHubLink] FWUP PROG: #{percent}%")
  end

  def handle_fwup_message({:error, _, message}) do
    Logger.error("[NervesHubLink] FWUP ERROR: #{message}")
  end

  def handle_fwup_message({:warning, _, message}) do
    Logger.warning("[NervesHubLink] FWUP WARN: #{message}")
  end

  def handle_fwup_message({:ok, status, message}) do
    Logger.info("[NervesHubLink] FWUP SUCCESS: #{status} #{message}")
  end

  def handle_fwup_message(fwup_message) do
    Logger.warning("[NervesHubLink] Unknown FWUP message: #{inspect(fwup_message)}")
  end

  @impl NervesHubLink.Client
  def handle_error(error) do
    Logger.warning("[NervesHubLink] error: #{inspect(error)}")
  end

  @impl NervesHubLink.Client
  def reconnect_backoff() do
    socket_config = Application.get_env(:nerves_hub_link, :socket, [])
    socket_config[:reconnect_after_msec]
  end

  @impl NervesHubLink.Client
  def identify() do
    Logger.info("[NervesHubLink] identifying")
  end
end
