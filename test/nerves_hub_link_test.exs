defmodule NervesHubLinkTest do
  use Slipstream.SocketTest, async: false

  alias NervesHubLink.ArchiveManager
  alias NervesHubLink.Client
  alias NervesHubLink.Configurator
  alias NervesHubLink.Socket
  alias NervesHubLink.FwupConfig
  alias NervesHubLink.PubSub
  alias NervesHubLink.UpdateManager

  doctest NervesHubLink

  defmodule Extension do
    use GenServer
    def start_link(opts) do
      GenServer.start_link(__MODULE__, opts, [])
    end

    def init(opts) do
      report_pid = opts[:report_to]
      PubSub.subscribe("device")
      {:ok, %{report_pid: report_pid}}
    end

    def push(pid, event, params) do
      GenServer.call(pid, {:push, event, params})
    end

    def handle_call({:push, event, params}, _from, state) do
      PubSub.publish_to_hub("device", event, params)
      {:reply, :ok, state}
    end

    def handle_info({:broadcast, :join, topic, reply}, state) do
      send(state.report_pid, {:joined, topic, reply})
      {:noreply, state}
    end

    def handle_info({:broadcast, :close, topic, reason}, state) do
      send(state.report_pid, {:closed, topic, reason})
      {:noreply, state}
    end

    def handle_info({:broadcast, :disconnect, topic, reason}, state) do
      send(state.report_pid, {:disconnected, topic, reason})
      {:noreply, state}
    end

    def handle_info({:broadcast, :msg, topic, event, params}, state) do
      send(state.report_pid, {:messaged, topic, event, params})
      {:noreply, state}
    end
  end

  setup do
    config = Configurator.build() |> Map.put(:connect, true)
    fwup_config = %FwupConfig{
      fwup_devpath: config.fwup_devpath,
      fwup_task: config.fwup_task,
      fwup_env: config.fwup_env,
      handle_fwup_message: &Client.handle_fwup_message/1,
      update_available: &Client.update_available/1
    }
    {:ok, _pid} = Supervisor.start_link([
      PubSub,
      {UpdateManager, fwup_config},
      {ArchiveManager, config},
      {Socket, config}
      ], strategy: :one_for_one, name: NervesHubLinkTest.Supervisor)
    {:ok, pid} = Extension.start_link(report_to: self())
    {:ok, ext_pid: pid}
  end

  test "join device channel", %{ext_pid: ext_pid} do
    connect_and_assert_join(Socket, "device", _, :ok)
    #assert_join("device", _, :ok)
    assert_join("console", _, :ok)
    assert_receive {:joined, "device", _}
    push(Socket, "device", "server-custom-event", %{myparam: 1})
    assert_receive {:messaged, "device", "server-custom-event", %{myparam: 1}}
    Extension.push(ext_pid, "device-custom-event", %{myparam: 2})
    assert_push("device", "device-custom-event", %{myparam: 2})
  end
end
