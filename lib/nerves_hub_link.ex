defmodule NervesHubLink do
  @doc """
  Checks if the device is connected to the NervesHub device channel.
  """
  @spec connected? :: boolean()
  def connected?() do
    NervesHubLink.Socket.check_connection(:device)
  end

  def console_connected?() do
    NervesHubLink.Socket.check_connection(:console)
  end

  @doc """
  Checks if the device has a socket connection with NervesHub
  """
  def socket_connected?() do
    NervesHubLink.Socket.check_connection(:socket)
  end

  @doc """
  Current status of the update manager
  """
  @spec status :: NervesHubLinkCommon.UpdateManager.State.status()
  defdelegate status(), to: NervesHubLinkCommon.UpdateManager

  @doc """
  Send update progress percentage for display in web
  """
  @spec send_update_progress(non_neg_integer()) :: :ok
  defdelegate send_update_progress(progress), to: NervesHubLink.Socket

  @doc """
  Send an update status to web
  """
  @spec send_update_status(String.t() | atom()) :: :ok
  defdelegate send_update_status(status), to: NervesHubLink.Socket
end
