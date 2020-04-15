defmodule NervesHubLink do
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
end
