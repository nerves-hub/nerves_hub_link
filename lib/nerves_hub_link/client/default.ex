defmodule NervesHubLink.Client.Default do
  @moduledoc """
  Default NervesHubLink.Client implementation

  This client always accepts an update.
  """

  @behaviour NervesHubLink.Client
  require Logger

  @impl NervesHubLink.Client
  def update_available(_), do: :apply

  @impl NervesHubLink.Client
  def handle_fwup_message({:progress, percent}, meta) do
    Logger.debug("FWUP PROG [#{meta.uuid}]: #{percent}%")
  end

  def handle_fwup_message({:error, _, message}, meta) do
    Logger.error("FWUP ERROR [#{meta.uuid}]: #{message}")
  end

  def handle_fwup_message({:warning, _, message}, meta) do
    Logger.warn("FWUP WARN [#{meta.uuid}]: #{message}")
  end

  def handle_fwup_message({:ok, status, message}, meta) do
    Logger.info("FWUP SUCCESS [#{meta.uuid}]: #{status} #{message}")
  end

  def handle_fwup_message(fwup_message, meta) do
    Logger.warn("Unknown FWUP message [#{meta.uuid}]: #{inspect(fwup_message)}")
  end

  @impl NervesHubLink.Client
  def handle_error(error) do
    Logger.warn("[NervesHubLink] error: #{inspect(error)}")
  end
end
