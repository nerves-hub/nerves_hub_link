defmodule NervesHubLink do
  alias NervesHubLink.Socket

  @doc """
  Checks if the device is connected to the NervesHub device channel.
  """
  @spec connected? :: boolean()
  def connected?() do
    Socket.check_connection(:device)
  end

  def console_connected?() do
    Socket.check_connection(:console)
  end

  @doc """
  Checks if the device has a socket connection with NervesHub
  """
  def socket_connected?() do
    Socket.check_connection(:socket)
  end

  @doc """
  Return whether there's currently an active console session
  """
  @spec console_active?() :: boolean()
  defdelegate console_active?, to: Socket

  @doc """
  Current status of the update manager
  """
  @spec status :: NervesHubLink.UpdateManager.State.status()
  defdelegate status(), to: NervesHubLink.UpdateManager

  @doc """
  Restart the socket and device channel
  """
  @spec reconnect() :: :ok
  defdelegate reconnect(), to: Socket

  @doc """
  Send update progress percentage for display in web
  """
  @spec send_update_progress(non_neg_integer()) :: :ok
  defdelegate send_update_progress(progress), to: Socket

  @doc """
  Send an update status to web
  """
  @spec send_update_status(String.t() | atom()) :: :ok
  defdelegate send_update_status(status), to: Socket

  @doc """
  Send a file to the connected console
  """
  @spec send_file(Path.t()) :: :ok
  defdelegate send_file(file_path), to: Socket
end
