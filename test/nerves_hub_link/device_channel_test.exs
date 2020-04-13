defmodule NervesHubLink.DeviceChannelTest do
  # Fwup can only have one instance at a time.
  # Set async false to account for this
  use ExUnit.Case, async: true
  alias NervesHubLink.{ClientMock, DeviceChannel}
  alias PhoenixClient.Message

  doctest DeviceChannel

  setup do
    # hack to stop Fwup streams if one was running
    try do
      if Process.whereis(Fwup.Stream), do: GenServer.stop(Fwup.Stream)
    catch
      _, _ -> :ok
    end

    %{state: %DeviceChannel.State{}}
  end

  setup context, do: Mox.verify_on_exit!(context)

  describe "handle_in/3 - update" do
    test "no firmware url" do
      Mox.expect(ClientMock, :update_available, 0, fn _ -> :ok end)
      assert DeviceChannel.handle_info(%Message{event: "update"}, %{}) == {:noreply, %{}}
    end

    test "firmware url - apply", %{state: state} do
      Mox.expect(ClientMock, :update_available, fn _ -> :apply end)

      assert DeviceChannel.handle_info(
               %Message{event: "update", payload: %{"firmware_url" => ""}},
               state
             ) == {:noreply, %DeviceChannel.State{status: {:updating, 0}}}
    end

    test "firmware url - ignore" do
      Mox.expect(ClientMock, :update_available, fn _ -> :ignore end)

      assert DeviceChannel.handle_info(
               %Message{event: "update", payload: %{"firmware_url" => ""}},
               %{}
             ) == {:noreply, %{}}
    end

    test "firmware url - reschedule", %{state: state} do
      data = %{"firmware_url" => ""}
      Mox.expect(ClientMock, :update_available, fn _ -> {:reschedule, 999} end)

      assert {:noreply, state} =
               DeviceChannel.handle_info(%Message{event: "update", payload: data}, state)

      Mox.expect(ClientMock, :update_available, fn _ -> {:reschedule, 1} end)

      assert {:noreply, %{} = state} =
               DeviceChannel.handle_info(%Message{event: "update", payload: data}, state)

      assert_receive {:update_reschedule, ^data}
    end

    test "firmware url - removes existing timer" do
      data = %{"firmware_url" => ""}
      Mox.expect(ClientMock, :update_available, fn _ -> :ignore end)

      assert {:noreply, state} =
               DeviceChannel.handle_info(%Message{event: "update", payload: data}, %{
                 update_reschedule_timer: nil
               })

      refute Map.has_key?(state, :update_reschedule_timer)
    end

    test "catch all" do
      assert DeviceChannel.handle_info(:any, :state) == {:noreply, :state}
    end

    test "update already in progress", %{state: state} do
      state = %{state | status: {:updating, 20}}

      # State is unchanged, effectively ignored
      assert {:noreply, ^state} =
               DeviceChannel.handle_info(
                 %Message{event: "update", payload: %{"firmware_url" => ""}},
                 state
               )
    end
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

  describe "handle_info" do
    test "fwup", %{state: state} do
      message = {:ok, 1, "message"}
      Mox.expect(ClientMock, :handle_fwup_message, fn ^message -> :ok end)
      assert DeviceChannel.handle_info({:fwup, message}, state) == {:noreply, state}
    end

    test "http_error", %{state: state} do
      error = "error"
      Mox.expect(ClientMock, :handle_error, fn ^error -> :apply end)

      assert DeviceChannel.handle_info({:http_error, error}, state) ==
               {:noreply, %DeviceChannel.State{status: :update_failed}}
    end

    test "update_reschedule", %{state: state} do
      data = %{"firmware_url" => ""}
      Mox.expect(ClientMock, :update_available, fn ^data -> :apply end)

      assert DeviceChannel.handle_info({:update_reschedule, data}, state) ==
               {:noreply, %DeviceChannel.State{status: {:updating, 0}}}
    end
  end

  describe "handle_info - down" do
    test "normal", %{state: state} do
      assert DeviceChannel.handle_info({:DOWN, :any, :process, :any, :normal}, state) ==
               {:noreply, state}
    end

    test "non-normal", %{state: state} do
      Mox.expect(ClientMock, :handle_error, 1, fn _ -> :ok end)

      assert DeviceChannel.handle_info({:DOWN, :any, :process, :any, :"non-normal"}, state) ==
               {:noreply, %DeviceChannel.State{status: :update_failed}}
    end
  end
end
