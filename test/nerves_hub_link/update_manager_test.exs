defmodule NervesHubLink.UpdateManagerTest do
  use ExUnit.Case, async: true
  alias NervesHubLink.{UpdateManager, ClientMock}

  doctest UpdateManager

  setup do
    # hack to stop Fwup streams if one was running
    try do
      if Process.whereis(Fwup.Stream), do: GenServer.stop(Fwup.Stream)
    catch
      _, _ -> :ok
    end

    %{state: %UpdateManager.State{}}
  end

  setup context, do: Mox.verify_on_exit!(context)

  describe "handle_call/3 - apply_update" do
    test "no firmware url", %{state: state} do
      Mox.expect(ClientMock, :update_available, 0, fn _ -> :ok end)
      assert UpdateManager.handle_call({:apply_update, %{}}, nil, state) == {:reply, :idle, state}
    end

    test "firmware url - apply", %{state: state} do
      Mox.expect(ClientMock, :update_available, fn _ -> :apply end)

      assert {:reply, {:updating, 0}, _} =
               UpdateManager.handle_call(
                 {:apply_update, %{"firmware_url" => ""}},
                 nil,
                 state
               )
    end

    test "firmware url - ignore", %{state: state} do
      Mox.expect(ClientMock, :update_available, fn _ -> :ignore end)

      assert {:reply, :idle, _} =
               UpdateManager.handle_call(
                 {:apply_update, %{"firmware_url" => ""}},
                 nil,
                 state
               )
    end

    test "firmware url - reschedule", %{state: state} do
      data = %{"firmware_url" => ""}
      Mox.expect(ClientMock, :update_available, fn _ -> {:reschedule, 999} end)

      assert {:reply, :update_rescheduled, _} =
               UpdateManager.handle_call({:apply_update, data}, nil, state)

      Mox.expect(ClientMock, :update_available, fn _ -> {:reschedule, 1} end)

      assert {:reply, :update_rescheduled, _} =
               UpdateManager.handle_call({:apply_update, data}, nil, state)

      assert_receive {:update_reschedule, ^data}
    end

    test "firmware url - removes existing timer", %{state: state} do
      data = %{"firmware_url" => ""}
      Mox.expect(ClientMock, :update_available, fn _ -> :ignore end)

      assert {:reply, _, state} =
               UpdateManager.handle_call(
                 {:apply_update, data},
                 nil,
                 %{state | update_reschedule_timer: Process.send_after(self(), :timer, 10_000)}
               )

      refute state.update_reschedule_timer
    end

    test "update already in progress", %{state: state} do
      state = %{state | status: {:updating, 20}}

      # State is unchanged, effectively ignored
      assert {:reply, _, ^state} =
               UpdateManager.handle_call(
                 {:apply_update, %{"firmware_url" => ""}},
                 nil,
                 state
               )
    end
  end

  describe "handle_info" do
    test "fwup", %{state: state} do
      message = {:ok, 1, "message"}
      Mox.expect(ClientMock, :handle_fwup_message, fn ^message -> :ok end)
      assert UpdateManager.handle_info({:fwup, message}, state) == {:noreply, state}
    end

    test "http_error", %{state: state} do
      error = "error"
      Mox.expect(ClientMock, :handle_error, fn ^error -> :apply end)

      assert UpdateManager.handle_info({:http_error, error}, state) ==
               {:noreply, %UpdateManager.State{status: :update_failed}}
    end

    test "update_reschedule", %{state: state} do
      data = %{"firmware_url" => ""}
      Mox.expect(ClientMock, :update_available, fn ^data -> :apply end)

      assert {:noreply, %UpdateManager.State{status: {:updating, 0}}} =
               UpdateManager.handle_info({:update_reschedule, data}, state)
    end
  end

  describe "handle_info - down" do
    test "normal", %{state: state} do
      assert {:noreply, state} =
               UpdateManager.handle_info({:DOWN, :any, :process, :any, :normal}, state)
    end

    test "non-normal", %{state: state} do
      Mox.expect(ClientMock, :handle_error, 1, fn _ -> :ok end)

      assert {:noreply, %UpdateManager.State{status: :update_failed}} =
               UpdateManager.handle_info({:DOWN, :any, :process, :any, :"non-normal"}, state)
    end
  end
end
