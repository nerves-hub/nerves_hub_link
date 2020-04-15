defmodule NervesHubLink.DeviceChannelTest do
  # Fwup can only have one instance at a time.
  # Set async false to account for this
  use ExUnit.Case, async: true
  alias NervesHubLink.DeviceChannel
  alias PhoenixClient.Message

  doctest DeviceChannel

  setup do
    %{state: %DeviceChannel.State{}}
  end

  test "handle_close", %{state: state} do
    # This fails without starting the connection Agent.
    # Not sure why
    # TODO: Manage this agent better. Remove from test
    NervesHubLink.Connection.start_link([])

    assert DeviceChannel.handle_info(%Message{event: "phx_close", payload: %{}}, state) ==
             {:noreply, %DeviceChannel.State{connected?: false}}

    assert_receive :join
  end
end
