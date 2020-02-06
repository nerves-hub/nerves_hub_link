defmodule NervesHubLink do
  @doc """
  Checks if the device is connected to the NervesHub channel.
  """
  @spec connected? :: boolean()
  def connected?() do
    channel_state()
    |> Map.get(:connected?, false)
  end

  @doc """
  Checks if the device has a socket connection with NervesHub
  """
  @dialyzer {:nowarn_function, {:socket_connected?, 0}}
  defdelegate socket_connected?(pid \\ NervesHubLink.Socket),
    to: PhoenixClient.Socket,
    as: :connected?

  @doc """
  Current status of the device channel
  """
  @spec status :: NervesHubLink.Channel.State.status()
  def status() do
    channel_state()
    |> Map.get(:status, :unknown)
  end

  defp channel_state() do
    GenServer.whereis(NervesHubLink.Channel)
    |> case do
      channel when is_pid(channel) -> GenServer.call(channel, :get_state)
      _ -> %{}
    end
  end
end
