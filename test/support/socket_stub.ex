# SPDX-FileCopyrightText: 2026 Josh Kalderimis
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule NervesHubLink.Support.SocketStub do
  @moduledoc """
  Stands in for `NervesHubLink.Socket` so that tests can observe the status
  updates that would otherwise be pushed to NervesHub.

  `NervesHubLink.send_update_status/1` casts to the process registered as
  `NervesHubLink.Socket`. Without a process under that name the cast is silently
  dropped, so anything that reports progress looks like it is working even when
  it isn't. Registering this stub instead forwards each status to the test
  process as `{:update_status, status}`.
  """

  use GenServer

  @spec start_link(pid()) :: GenServer.on_start()
  def start_link(test_pid) do
    GenServer.start_link(__MODULE__, test_pid, name: NervesHubLink.Socket)
  end

  @impl GenServer
  def init(test_pid) do
    {:ok, test_pid}
  end

  @impl GenServer
  def handle_cast({:send_update_status, status}, test_pid) do
    send(test_pid, {:update_status, status})
    {:noreply, test_pid}
  end

  def handle_cast(message, test_pid) do
    send(test_pid, {:socket_cast, message})
    {:noreply, test_pid}
  end
end
