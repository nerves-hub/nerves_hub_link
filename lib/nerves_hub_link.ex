defmodule NervesHubLink do
  alias NervesHubLink.Socket

  @doc """
  Checks if the device is connected to the NervesHub device channel.
  """
  @spec connected? :: boolean()
  def connected?() do
    Socket.check_connection(Socket, :device)
  end

  def console_connected?() do
    Socket.check_connection(Socket, :console)
  end

  @doc """
  Checks if the device has a socket connection with NervesHub
  """
  def socket_connected?() do
    Socket.check_connection(Socket, :socket)
  end

  @doc """
  Return whether there's currently an active console session
  """
  @spec console_active?() :: boolean()
  def console_active?, do: Socket.console_active?(Socket)

  @doc """
  Current status of the update manager
  """
  @spec status :: NervesHubLink.UpdateManager.State.status()
  def status(), do: NervesHubLink.UpdateManager.status(Socket)

  @doc """
  Restart the socket and device channel
  """
  @spec reconnect_socket() :: :ok
  def reconnect_socket(), do: Socket.reconnect_socket(Socket)

  @doc """
  Send update progress percentage for display in web
  """
  @spec send_update_progress(non_neg_integer()) :: :ok
  def send_update_progress(progress), do: Socket.send_update_progress(Socket, progress)

  @doc """
  Send an update status to web
  """
  @spec send_update_status(String.t() | atom()) :: :ok
  def send_update_status(status), do: Socket.send_update_status(Socket, status)
end
