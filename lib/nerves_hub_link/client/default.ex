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
  def handle_fwup_message({:progress, percent}) do
    Logger.debug("FWUP PROG: #{percent}%")
  end

  def handle_fwup_message({:error, _, message}) do
    Logger.error("FWUP ERROR: #{message}")
  end

  def handle_fwup_message({:warning, _, message}) do
    Logger.warn("FWUP WARN: #{message}")
  end

  def handle_fwup_message({:ok, status, message}) do
    Logger.info("FWUP SUCCESS: #{status} #{message}")
  end

  def handle_fwup_message(fwup_message) do
    Logger.warn("Unknown FWUP message: #{inspect(fwup_message)}")
  end

  @impl NervesHubLink.Client
  def handle_error(error) do
    Logger.warn("[NervesHubLink] error: #{inspect(error)}")
  end

  @impl NervesHubLink.Client
  def identify() do
    Logger.info("[NervesHubLink] identifying")
  end
end
