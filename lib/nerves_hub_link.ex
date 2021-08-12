defmodule NervesHubLink do
  alias NervesHubLink.Supervisor, as: NHLSupervisor
  alias NervesHubLink.{ConsoleChannel, DeviceChannel, Socket}

  @doc """
  Checks if the device is connected to the NervesHub channel.
  """
  @spec connected? :: boolean()
  defdelegate connected?(), to: NervesHubLink.DeviceChannel

  @doc """
  Checks if the device has a socket connection with NervesHub
  """
  @dialyzer {:nowarn_function, {:socket_connected?, 0}}
  defdelegate socket_connected?(pid \\ NervesHubLink.Socket),
    to: PhoenixClient.Socket,
    as: :connected?

  @doc """
  Current status of the update manager
  """
  @spec status :: NervesHubLinkCommon.UpdateManager.State.status()
  defdelegate status(), to: NervesHubLinkCommon.UpdateManager

  @doc """
  Restart the socket and device channel
  """
  @spec reconnect() :: :ok
  def reconnect() do
    # Stop the socket last
    _ = Supervisor.terminate_child(NHLSupervisor, ConsoleChannel)
    _ = Supervisor.terminate_child(NHLSupervisor, DeviceChannel)
    _ = Supervisor.terminate_child(NHLSupervisor, Socket)

    # Start the socket first
    _ = Supervisor.restart_child(NHLSupervisor, Socket)
    _ = Supervisor.restart_child(NHLSupervisor, ConsoleChannel)
    _ = Supervisor.restart_child(NHLSupervisor, DeviceChannel)

    :ok
  end
end
