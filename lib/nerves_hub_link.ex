defmodule NervesHubLink do
  alias __MODULE__.Supervisor, as: NHLSupervisor
  alias __MODULE__.{ConsoleChannel, DeviceChannel, Socket}

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
  @spec status :: NervesHubLink.UpdateManager.State.status()
  defdelegate status(), to: NervesHubLink.UpdateManager

  @doc """
  Restart the socket and device channel
  """
  @spec reconnect() :: :ok
  def reconnect() do
    for {id, _child, _type, _modules} <- Supervisor.which_children(NHLSupervisor),
        id in [Socket, DeviceChannel, ConsoleChannel] do
      _ = Supervisor.terminate_child(NHLSupervisor, id)
      _ = Supervisor.restart_child(NHLSupervisor, id)
    end

    :ok
  end
end
