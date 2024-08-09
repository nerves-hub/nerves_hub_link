defmodule NervesHubLink.Client.Default do
  @moduledoc """
  Default NervesHubLink.Client implementation

  This client always accepts an update.
  """

  @behaviour NervesHubLink.Client

  alias NervesHubLink.Message.DeviceStatus
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

  @impl NervesHubLink.Client
  def check_health() do
    config = Application.get_env(:nerves_hub_link, :health)

    if config == false do
      # No check at all, disabled
      nil
    else
      report = config[:report] || NervesHubLink.HealthCheck.DefaultReport

      DeviceStatus.new(
        timestamp: report.timestamp(),
        metadata: report.metadata(),
        alarms: report.alarms(),
        metrics: report.metrics(),
        peripherals: report.peripherals()
      )
    end
  rescue
    _ ->
      :alarm_handler.set_alarm({NervesHubLink.HealthCheckFailed, []})

      DeviceStatus.new(
        timestamp: DateTime.utc_now(),
        metadata: %{},
        alarms: %{to_string(NervesHubLink.HealthCheckFailed) => []},
        metrics: %{},
        peripherals: %{}
      )
  end
end
